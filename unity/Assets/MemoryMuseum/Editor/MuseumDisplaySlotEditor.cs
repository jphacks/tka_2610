using UnityEngine;
using UnityEditor;
namespace LumenMuseum.EditorTools
{
    [CustomEditor(typeof(MuseumDisplaySlot))]
    public sealed class MuseumDisplaySlotEditor : UnityEditor.Editor
    {
        public override void OnInspectorGUI()
        {
            DrawDefaultInspector();
            MuseumDisplaySlot slot = (MuseumDisplaySlot)target;
            EditorGUILayout.Space();
            EditorGUILayout.HelpBox("Drag any imported 3D prefab into Assigned Prefab, then place it. For runtime catalog selection and saved layouts, also add it to the generated MuseumCatalog asset with a unique ID. Move the DISPLAY_SLOT parent to move the plinth, collider and exhibit together.", MessageType.Info);
            using (new EditorGUI.DisabledScope(slot.assignedPrefab == null))
            {
                if (GUILayout.Button("Place Assigned Prefab (auto-fit)"))
                {
                    Undo.RegisterFullObjectHierarchyUndo(slot.gameObject, "Place museum memory");
                    slot.PlaceAssignedPrefab(); EditorUtility.SetDirty(slot);
                    UnityEditor.SceneManagement.EditorSceneManager.MarkSceneDirty(slot.gameObject.scene);
                }
            }
            if (GUILayout.Button("Clear Display"))
            {
                Undo.RegisterFullObjectHierarchyUndo(slot.gameObject, "Clear museum display");
                slot.ClearDisplay(); EditorUtility.SetDirty(slot);
                UnityEditor.SceneManagement.EditorSceneManager.MarkSceneDirty(slot.gameObject.scene);
            }
        }
    }
}
