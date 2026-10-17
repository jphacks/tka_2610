using System;
using UnityEngine;

namespace LumenMuseum
{
    /// <summary>A real, movable display anchor. The mesh is fitted above the plinth,
    /// retaining depth and allowing a complete orbit. No images or billboards are used.</summary>
    public sealed class MuseumDisplaySlot : MonoBehaviour
    {
        public string slotId;
        public string memoryTitle = "Your memory";
        public string memoryDate = "2026-09-15";
        public string memoryLocation = "Personal archive";
        [TextArea(2, 6)] public string memoryNote;
        public Vector3 displayVolume = new Vector3(0.85f, 0.90f, 0.75f);
        [Tooltip("Any imported 3D prefab. Use the Place Assigned Prefab button below.")]
        public GameObject assignedPrefab;
        [SerializeField] private Transform contentPivot;
        [SerializeField] private string currentItemId = "";
        [SerializeField] private float yaw;
        [SerializeField, Range(0.2f, 1f)] private float sizeMultiplier = 1f;
        [SerializeField] private float fitScale = 1f;

        public string CurrentItemId { get { return currentItemId; } }
        public float Yaw { get { return yaw; } }
        public float SizeMultiplier { get { return sizeMultiplier; } }
        public bool HasContent { get { return contentPivot != null && contentPivot.childCount > 0; } }

        public bool PlacePrefab(GameObject prefab, string stableId = "", float angle = 0f, float scale = 1f)
        {
            if (prefab == null) return false;
            ClearDisplay();
            GameObject pivot = new GameObject("DisplayedMemory");
            contentPivot = pivot.transform;
            contentPivot.SetParent(transform, false);
            GameObject instance = Instantiate(prefab, contentPivot, false);
            instance.name = prefab.name;
            instance.transform.localPosition = Vector3.zero;
            instance.transform.localRotation = Quaternion.identity;
            instance.SetActive(true);
            // Keepsakes are exhibits, not physics obstacles. The plinth/case has its own collider.
            foreach (Collider c in instance.GetComponentsInChildren<Collider>(true)) c.enabled = false;
            foreach (Rigidbody rb in instance.GetComponentsInChildren<Rigidbody>(true)) rb.isKinematic = true;

            Renderer[] renderers = instance.GetComponentsInChildren<Renderer>(true);
            bool haveBounds = false;
            Bounds bounds = new Bounds();
            foreach (Renderer r in renderers)
            {
                if (r is ParticleSystemRenderer || !r.gameObject.activeInHierarchy) continue;
                Bounds world = r.bounds;
                for (int k = 0; k < 8; k++)
                {
                    Vector3 p = world.center + Vector3.Scale(world.extents,
                        new Vector3((k & 1) == 0 ? -1 : 1, (k & 2) == 0 ? -1 : 1, (k & 4) == 0 ? -1 : 1));
                    p = contentPivot.InverseTransformPoint(p);
                    if (!haveBounds) { bounds = new Bounds(p, Vector3.zero); haveBounds = true; }
                    else bounds.Encapsulate(p);
                }
            }
            if (!haveBounds || bounds.size.sqrMagnitude < 0.000001f)
            {
                ClearDisplay();
                Debug.LogWarning("The selected prefab has no usable visible mesh.", this);
                return false;
            }
            // Fit the horizontal diagonal, so rotation cannot push the object through the case.
            float diameter = Mathf.Max(0.001f, new Vector2(bounds.size.x, bounds.size.z).magnitude);
            fitScale = Mathf.Min(displayVolume.x / diameter, displayVolume.z / diameter,
                displayVolume.y / Mathf.Max(0.001f, bounds.size.y)) * 0.90f;
            instance.transform.localPosition -= new Vector3(bounds.center.x, bounds.min.y, bounds.center.z);
            currentItemId = stableId ?? "";
            assignedPrefab = prefab;
            yaw = float.IsNaN(angle) ? 0 : Mathf.Repeat(angle, 360f);
            sizeMultiplier = float.IsNaN(scale) ? 1 : Mathf.Clamp(scale, 0.2f, 1f);
            ApplyPose();
            return true;
        }

        public void RotateBy(float degrees) { yaw = Mathf.Repeat(yaw + degrees, 360f); ApplyPose(); }
        public void SetSize(float scale) { sizeMultiplier = Mathf.Clamp(scale, 0.2f, 1f); ApplyPose(); }
        private void ApplyPose()
        {
            if (contentPivot == null) return;
            contentPivot.localRotation = Quaternion.Euler(0, yaw, 0);
            contentPivot.localScale = Vector3.one * fitScale * sizeMultiplier;
        }

        [ContextMenu("Place Assigned Prefab")]
        public void PlaceAssignedPrefab()
        {
            if (assignedPrefab != null) PlacePrefab(assignedPrefab, currentItemId, yaw, sizeMultiplier);
        }

        [ContextMenu("Clear Display")]
        public void ClearDisplay()
        {
            if (contentPivot != null)
            {
                // Deactivate before deferred Destroy, so a replaced item cannot be rendered twice.
                contentPivot.gameObject.SetActive(false);
                if (Application.isPlaying) Destroy(contentPivot.gameObject);
                else DestroyImmediate(contentPivot.gameObject);
            }
            contentPivot = null;
            currentItemId = "";
        }

        private void OnDrawGizmosSelected()
        {
            Gizmos.color = new Color(0.15f, 0.65f, 0.70f, 0.8f);
            Gizmos.matrix = transform.localToWorldMatrix;
            Gizmos.DrawWireCube(Vector3.up * displayVolume.y * 0.5f, displayVolume);
            Gizmos.DrawLine(Vector3.zero, Vector3.up * 0.3f);
        }
    }
}
