using System;
namespace LumenMuseum.EditorTools
{
    [Serializable] public sealed class MuseumMaterialData
    {
        public string name, texture;
        public float[] color;
        public float roughness, metallic, alpha, emission;
    }
    [Serializable] public sealed class MuseumColliderData
    {
        public string type, name, group;
        public float[] center, size, vertices;
        public int[] triangles;
    }
    [Serializable] public sealed class MuseumSlotData
    {
        public string id, group, geometryGroup, sample, title, location, date, note;
        public float[] position, size;
        public float rotation;
        public int labelIndex;
    }
    [Serializable] public sealed class MuseumLightData
    {
        public string name, kind, group;
        public float[] position, color;
        public float power, range;
    }
    [Serializable] public sealed class MuseumManifest
    {
        public int formatVersion;
        public string title, units, axis;
        public float[] playerSpawn;
        public float upperFloor;
        public MuseumMaterialData[] materials;
        public MuseumColliderData[] colliders;
        public MuseumSlotData[] slots;
        public MuseumLightData[] lights;
    }
}
