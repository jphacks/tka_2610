using System;
using UnityEngine;
namespace LumenMuseum
{
    public sealed class MuseumExpansion : MonoBehaviour
    {
        public GameObject westWing, eastWing, westGate, eastGate;
        public MuseumWalker walker;
        public event Action Changed;
        public bool WestOpen { get { return westWing != null && westWing.activeSelf; } }
        public bool EastOpen { get { return eastWing != null && eastWing.activeSelf; } }

        public bool SetWing(bool west, bool open, bool force = false)
        {
            if (!open && !force && walker != null)
            {
                float x = walker.transform.position.x;
                // Never remove the floor underneath a visitor.
                if ((west && x < -13f) || (!west && x > 13f)) return false;
            }
            GameObject wing = west ? westWing : eastWing;
            GameObject gate = west ? westGate : eastGate;
            if (wing != null) wing.SetActive(open);
            if (gate != null) gate.SetActive(!open);
            Physics.SyncTransforms();
            if (Changed != null) Changed();
            return true;
        }
    }
}
