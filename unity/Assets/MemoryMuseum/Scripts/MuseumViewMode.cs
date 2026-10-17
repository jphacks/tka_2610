using System.Collections.Generic;
using UnityEngine;
namespace LumenMuseum
{
    public sealed class MuseumViewMode : MonoBehaviour
    {
        public Camera walkthroughCamera, overviewCamera;
        public MuseumWalker walker;
        [Tooltip("Only the roof, upper floors and front wall are hidden for the dollhouse view.")]
        public GameObject[] hideInOverview;
        public bool IsOverview { get; private set; }
        private readonly Dictionary<GameObject, bool> previousStates = new Dictionary<GameObject, bool>();
        public void SetOverview(bool value)
        {
            if (value == IsOverview || overviewCamera == null || walkthroughCamera == null) return;
            IsOverview = value;
            if (value)
            {
                previousStates.Clear();
                if (hideInOverview != null) foreach (GameObject go in hideInOverview)
                {
                    if (go == null || previousStates.ContainsKey(go)) continue;
                    previousStates.Add(go, go.activeSelf); go.SetActive(false);
                }
            }
            else
            {
                foreach (KeyValuePair<GameObject, bool> state in previousStates)
                    if (state.Key != null) state.Key.SetActive(state.Value);
                previousStates.Clear();
            }
            overviewCamera.enabled = value;
            walkthroughCamera.enabled = !value;
            if (walker != null) { walker.Suspended = value; walker.LockCursor(!value); }
        }
        private void OnDisable() { if (IsOverview) SetOverview(false); }
    }
}
