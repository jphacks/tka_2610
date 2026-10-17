using System;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEditor;

namespace LumenMuseum.EditorTools
{
    public static class MuseumSceneValidator
    {
        [MenuItem("Tools/Lumen Museum/2 - Validate Open Scene")]
        public static void ValidateMenu() { Debug.Log(Validate(true)); }

        public static string Validate(bool showDialog)
        {
            var report = new StringBuilder("LUMEN MUSEUM / UNITY SCENE VALIDATION\n");
            report.AppendLine(DateTime.Now.ToString("s"));
            int errors = 0;
            MuseumDisplaySlot[] slots = UnityEngine.Object.FindObjectsOfType<MuseumDisplaySlot>(true);
            MuseumWalker walker = UnityEngine.Object.FindObjectOfType<MuseumWalker>();
            foreach (var duplicate in slots.Where(s => s != null).GroupBy(s => s.slotId).Where(g => g.Count() > 1))
            { report.AppendLine("ERROR duplicate slot ID: " + duplicate.Key); errors++; }
            if (walker == null) { report.AppendLine("ERROR visitor controller missing."); errors++; }
            else if (walker.viewCamera == null) { report.AppendLine("ERROR visitor camera missing."); errors++; }
            int meshCount = 0, triangles = 0;
            foreach (MeshFilter filter in UnityEngine.Object.FindObjectsOfType<MeshFilter>(true))
            {
                if (filter.sharedMesh == null) { report.AppendLine("ERROR missing mesh: " + filter.name); errors++; continue; }
                meshCount++; triangles += (int)filter.sharedMesh.GetIndexCount(0) / 3;
            }
            foreach (MeshRenderer renderer in UnityEngine.Object.FindObjectsOfType<MeshRenderer>(true))
                if (renderer.sharedMaterial == null || renderer.sharedMaterial.shader == null || !renderer.sharedMaterial.shader.isSupported)
                { report.AppendLine("ERROR missing/unsupported material: " + renderer.name); errors++; }
            Physics.SyncTransforms();
            // These are clear walking positions, not the centres of occupied display plinths.
            Vector3[] groundSamples = {
                new Vector3(0,0,-12.3f), new Vector3(-2.5f,0,-8), new Vector3(2.5f,0,-8),
                new Vector3(0,0,-2), new Vector3(0,0,1.8f),
                new Vector3(-6.45f,0,-7.2f), new Vector3(6.45f,0,-7.2f),
                new Vector3(-10.9f,0,-5.8f), new Vector3(10.9f,0,-5.8f),
                new Vector3(-9.6f,0,2), new Vector3(9.6f,0,2),
                new Vector3(-10.9f,0,8.5f), new Vector3(10.9f,0,8.5f)
            };
            int samples = 0;
            foreach (Vector3 p in groundSamples) { errors += CheckWalkPoint(p, report); samples++; }
            for (int i = 0; i <= 14; i++)
            {
                float t = i / 14f;
                errors += CheckWalkPoint(new Vector3(0, 2.1f * t, Mathf.Lerp(2.8f, 6.2f, t)), report); samples++;
                errors += CheckWalkPoint(new Vector3(0, 2.1f + 2.1f * t, Mathf.Lerp(7.4f, 10.8f, t)), report); samples++;
            }
            foreach (Vector3 p in new[] { new Vector3(0,2.1f,6.8f), new Vector3(0,4.22f,11.5f),
                new Vector3(-7.4f,4.22f,12),new Vector3(7.4f,4.22f,12),new Vector3(-7.4f,4.22f,0),
                new Vector3(7.4f,4.22f,0),new Vector3(0,4.22f,-11.8f) })
            { errors += CheckWalkPoint(p, report); samples++; }
            report.AppendLine("Slots (including annexes): " + slots.Length);
            report.AppendLine("Mesh renderers: " + meshCount + " / triangles including instances: " + triangles);
            report.AppendLine("Walking support / clearance samples: " + samples);
            report.AppendLine("Errors: " + errors);
            report.AppendLine("This validates scene data and sampled Physics queries, not all gameplay paths, target-device performance or every rendering pipeline.");
            if (showDialog) EditorUtility.DisplayDialog("Lumen scene validation", errors == 0 ? "No issues in the sampled checks. See the Console for the full report." : errors + " issue(s) found. See the Console for the report.", "OK");
            return report.ToString();
        }
        private static int CheckWalkPoint(Vector3 feet, StringBuilder report)
        {
            if (!Physics.Raycast(feet + Vector3.up * 0.35f, Vector3.down, out RaycastHit support, 0.9f, ~0, QueryTriggerInteraction.Ignore))
            { report.AppendLine("ERROR no floor at " + feet); return 1; }
            if (support.normal.y < 0.60f)
            { report.AppendLine("ERROR excessive support slope at " + feet); return 1; }
            // Lift the lower test sphere to avoid counting normal contact with the sloped floor.
            Collider[] blockers = Physics.OverlapCapsule(feet + Vector3.up * 0.48f, feet + Vector3.up * 1.55f, 0.23f, ~0, QueryTriggerInteraction.Ignore);
            blockers = blockers.Where(c => !(c is CharacterController) && c != support.collider).ToArray();
            if (blockers.Length > 0)
            { report.AppendLine("ERROR standing clearance at " + feet + ": " + string.Join(", ", blockers.Select(c => c.name))); return 1; }
            return 0;
        }
    }
}
