using System;
using UnityEngine;

namespace LumenMuseum
{
    [Serializable]
    public sealed class MuseumMemory
    {
        public string id;
        public string title;
        [TextArea(2, 6)] public string description;
        public GameObject prefab;
    }

    [CreateAssetMenu(fileName = "MuseumCatalog", menuName = "Lumen Museum/Memory Catalog")]
    public sealed class MuseumCatalog : ScriptableObject
    {
        public MuseumMemory[] memories = Array.Empty<MuseumMemory>();
        public MuseumMemory Find(string id)
        {
            if (string.IsNullOrEmpty(id) || memories == null) return null;
            foreach (MuseumMemory item in memories)
                if (item != null && item.id == id) return item;
            return null;
        }
    }
}
