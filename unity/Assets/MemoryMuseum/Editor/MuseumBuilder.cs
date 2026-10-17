using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine.SceneManagement;

namespace LumenMuseum.EditorTools
{
    /// <summary>Creates native Unity meshes, materials, movable plinths, colliders,
    /// prefabs and a playable scene. No Blender, glTF package or network access is required.</summary>
    public static class MuseumBuilder
    {
        public const string Root = "Assets/MemoryMuseum";
        public const string Generated = Root + "/Generated";
        private sealed class Chunk
        {
            public string name, group;
            public int material;
            public Vector3[] vertices, normals;
            public Vector2[] uv;
            public int[] triangles;
        }
        private static MuseumManifest manifest;
        private static Material[] materials;
        private static Dictionary<string, GameObject> groups;
        private static GameObject stage;
        private static bool urp;

        [MenuItem("Tools/Lumen Museum/1 - Build Walkable Demo")]
        public static void BuildDemo()
        {
            if (EditorApplication.isPlayingOrWillChangePlaymode)
            { EditorUtility.DisplayDialog("Lumen Museum", "Stop Play Mode before building the scene.", "OK"); return; }
            string manifestPath = Root + "/Data/MuseumManifest.json";
            if (!File.Exists(manifestPath))
            { EditorUtility.DisplayDialog("Lumen Museum", "Keep the supplied folder at Assets/MemoryMuseum. The model manifest was not found.", "OK"); return; }
            RenderPipelineAsset pipeline = GraphicsSettings.currentRenderPipeline;
            urp = pipeline != null && pipeline.GetType().Name.IndexOf("Universal", StringComparison.OrdinalIgnoreCase) >= 0;
            if (pipeline != null && !urp)
            {
                EditorUtility.DisplayDialog("Unsupported render pipeline",
                    "This automated scene setup targets Built-in and Universal Render Pipeline. Use a 3D Built-in or URP project. The separate OBJ/GLB geometry can still be used in other pipelines after material conversion.", "OK"); return;
            }
            if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;
            if (Directory.Exists(Generated) && !EditorUtility.DisplayDialog("Rebuild generated assets?",
                    "Files in Assets/MemoryMuseum/Generated will be regenerated. Save custom scene/prefab changes outside that folder first. No project settings or external folders are changed.", "Rebuild", "Cancel")) return;
            try
            {
                manifest = JsonUtility.FromJson<MuseumManifest>(File.ReadAllText(manifestPath));
                if (manifest == null || manifest.formatVersion != 1 || manifest.materials == null || manifest.slots == null)
                    throw new InvalidDataException("Unsupported or incomplete museum manifest.");
                foreach (string path in new[] { Generated, Generated + "/Meshes", Generated + "/Materials", Generated + "/Prefabs", Generated + "/Scenes" })
                    Directory.CreateDirectory(path);
                AssetDatabase.Refresh();
                PrepareTextures();
                materials = CreateMaterials();
                // All assets are created through Unity's public API, not handwritten scene YAML.
                Scene scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                stage = new GameObject("Lumen_MemoryMuseum");
                groups = new Dictionary<string, GameObject>();
                List<Chunk> architecture = ReadGeometry(Root + "/Data/MuseumGeometry.bytes");
                int index = 0;
                foreach (Chunk chunk in architecture)
                {
                    EditorUtility.DisplayProgressBar("Lumen Museum", "Building " + chunk.group, (float)index++ / (architecture.Count + 30));
                    GameObject parent = GetGroup(chunk.group);
                    Vector3 pivot = parent.transform.position;
                    if (pivot != Vector3.zero)
                        for (int i = 0; i < chunk.vertices.Length; i++) chunk.vertices[i] -= pivot;
                    Mesh mesh = CreateMesh(chunk, "Stage_" + chunk.name, true);
                    GameObject meshObject = new GameObject(chunk.name);
                    meshObject.transform.SetParent(parent.transform, false);
                    meshObject.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer renderer = meshObject.AddComponent<MeshRenderer>();
                    renderer.sharedMaterial = materials[chunk.material];
                    renderer.shadowCastingMode = manifest.materials[chunk.material].alpha < 1 ? ShadowCastingMode.Off : ShadowCastingMode.On;
                    renderer.receiveShadows = true;
                    // The exhibition furniture is intentionally not statically batched: it remains movable.
                    if (!chunk.group.StartsWith("DISPLAY_", StringComparison.Ordinal))
                        GameObjectUtility.SetStaticEditorFlags(meshObject, StaticEditorFlags.BatchingStatic | StaticEditorFlags.ContributeGI);
                }
                MuseumCatalog catalog = CreateCatalog();
                Dictionary<string, MuseumDisplaySlot> slots = CreateSlots(catalog);
                CreateColliders(slots);
                CreateGalleryLights();
                GameObject visitor = CreateVisitor(out MuseumWalker walker, out Camera walkCamera);
                GameObject experienceObject = new GameObject("Museum_Experience");
                MuseumExpansion expansion = experienceObject.AddComponent<MuseumExpansion>();
                expansion.westWing = GetGroup("Annex_West"); expansion.eastWing = GetGroup("Annex_East");
                expansion.westGate = GetGroup("Gate_West"); expansion.eastGate = GetGroup("Gate_East");
                expansion.walker = walker;
                expansion.SetWing(true, false, true); expansion.SetWing(false, false, true);
                MuseumViewMode mode = experienceObject.AddComponent<MuseumViewMode>();
                mode.walker = walker; mode.walkthroughCamera = walkCamera;
                GameObject overview = new GameObject("Museum_OverviewCamera"); overview.transform.SetParent(experienceObject.transform, false);
                overview.transform.position = new Vector3(33, 33, -40); overview.transform.LookAt(new Vector3(0, 1, 0));
                Camera mapCamera = overview.AddComponent<Camera>(); mapCamera.orthographic = true; mapCamera.orthographicSize = 24;
                mapCamera.nearClipPlane = 0.1f; mapCamera.farClipPlane = 140; mapCamera.allowHDR = true;
                mapCamera.clearFlags = CameraClearFlags.SolidColor; mapCamera.backgroundColor = new Color(0.83f, 0.85f, 0.84f); mapCamera.enabled = false;
                mode.overviewCamera = mapCamera;
                var hide = new List<GameObject>();
                foreach (KeyValuePair<string, GameObject> pair in groups)
                {
                    string n = pair.Key;
                    if (n.Contains("_Upper") || n == "Roof" || n.StartsWith("AnnexRoof_") || n == "Mezzanine" ||
                        n == "LightingFixtures" || n == "Exterior_Front" || n == "Vestibule" || n == "ExteriorContext" ||
                        (n.StartsWith("DISPLAY_") && pair.Value.transform.position.y > 3.9f)) hide.Add(pair.Value);
                }
                mode.hideInOverview = hide.ToArray();
                MuseumExperience experience = experienceObject.AddComponent<MuseumExperience>();
                experience.catalog = catalog; experience.slots = slots.Values.OrderBy(s => s.slotId).ToArray();
                experience.walker = walker; experience.expansion = expansion; experience.viewMode = mode;
                CreateDaylight(walkCamera);
                SavePrefabs(slots, catalog);
                string scenePath = Generated + "/Scenes/LumenMuseum_Demo.unity";
                EditorSceneManager.MarkSceneDirty(scene);
                EditorSceneManager.SaveScene(scene, scenePath);
                AssetDatabase.SaveAssets(); AssetDatabase.Refresh(); Physics.SyncTransforms();
                Selection.activeGameObject = visitor;
                if (SceneView.lastActiveSceneView != null)
                    SceneView.lastActiveSceneView.LookAt(new Vector3(0, 3, 1), Quaternion.Euler(35, -35, 0), 24f);
                string report = MuseumSceneValidator.Validate(false);
                File.WriteAllText(Generated + "/ValidationReport.txt", report);
                Debug.Log("Lumen Museum created. Open " + scenePath + " and press Play.\n" + report);
                EditorUtility.ClearProgressBar();
                EditorUtility.DisplayDialog("Lumen Museum is ready",
                    "Native meshes, 30 display slots, collision proxies and the demo scene were created.\n\nPress Play, click the Game view, then use WASD.\nE: curate / M: floor plan / B: expansion.\n\nThe console contains the scene validation report.", "OK");
            }
            catch (Exception ex)
            {
                Debug.LogException(ex); EditorUtility.ClearProgressBar();
                EditorUtility.DisplayDialog("Museum build stopped", ex.Message + "\nDetails are in the Console. Existing source data was not changed.", "OK");
            }
            finally { EditorUtility.ClearProgressBar(); }
        }

        private static void PrepareTextures()
        {
            foreach (string file in Directory.GetFiles(Root + "/Textures", "*.png"))
            {
                string path = file.Replace('\\', '/');
                TextureImporter importer = AssetImporter.GetAtPath(path) as TextureImporter;
                if (importer == null) continue;
                importer.textureType = TextureImporterType.Default;
                importer.sRGBTexture = true; importer.mipmapEnabled = true;
                importer.wrapMode = TextureWrapMode.Repeat; importer.filterMode = FilterMode.Trilinear; importer.anisoLevel = 8;
                importer.maxTextureSize = 2048;
                importer.textureCompression = path.Contains("Labels") || path.Contains("Studies") ? TextureImporterCompression.Uncompressed : TextureImporterCompression.CompressedHQ;
                importer.SaveAndReimport();
            }
        }
        private static Material[] CreateMaterials()
        {
            Shader shader = Shader.Find(urp ? "Universal Render Pipeline/Lit" : "Standard");
            if (shader == null) throw new InvalidOperationException("The selected render pipeline's Lit shader is not available.");
            var result = new Material[manifest.materials.Length];
            for (int i = 0; i < result.Length; i++)
            {
                MuseumMaterialData d = manifest.materials[i];
                Material material = new Material(shader) { name = "Lumen_" + d.name };
                Color color = new Color(d.color[0], d.color[1], d.color[2], d.alpha);
                material.SetColor(urp ? "_BaseColor" : "_Color", color);
                material.SetFloat("_Metallic", d.metallic);
                material.SetFloat(urp ? "_Smoothness" : "_Glossiness", 1f - d.roughness);
                if (!string.IsNullOrEmpty(d.texture))
                {
                    Texture2D texture = AssetDatabase.LoadAssetAtPath<Texture2D>(Root + "/Textures/" + d.texture);
                    if (texture == null) throw new FileNotFoundException("Missing material texture: " + d.texture);
                    material.SetTexture(urp ? "_BaseMap" : "_MainTex", texture);
                }
                bool doubleSided = d.name.StartsWith("Leaf") || d.alpha < 1;
                if (material.HasProperty("_Cull")) material.SetFloat("_Cull", doubleSided ? 0 : 2);
                material.doubleSidedGI = doubleSided;
                if (d.alpha < 1f)
                {
                    material.SetOverrideTag("RenderType", "Transparent");
                    material.renderQueue = (int)RenderQueue.Transparent;
                    material.SetInt("_SrcBlend", (int)BlendMode.SrcAlpha);
                    material.SetInt("_DstBlend", (int)BlendMode.OneMinusSrcAlpha);
                    material.SetInt("_ZWrite", 0);
                    if (urp)
                    {
                        material.SetFloat("_Surface", 1); material.SetFloat("_Blend", 0);
                        material.EnableKeyword("_SURFACE_TYPE_TRANSPARENT");
                        material.DisableKeyword("_ALPHAPREMULTIPLY_ON");
                    }
                    else
                    {
                        material.SetFloat("_Mode", 2);
                        material.EnableKeyword("_ALPHABLEND_ON");
                        material.DisableKeyword("_ALPHATEST_ON");
                        material.DisableKeyword("_ALPHAPREMULTIPLY_ON");
                    }
                }
                if (d.emission > 0)
                {
                    material.EnableKeyword("_EMISSION");
                    material.SetColor("_EmissionColor", new Color(d.color[0], d.color[1], d.color[2]) * d.emission);
                    material.globalIlluminationFlags = MaterialGlobalIlluminationFlags.BakedEmissive;
                }
                string path = Generated + "/Materials/" + material.name + ".mat";
                ReplaceAsset(material, path); result[i] = AssetDatabase.LoadAssetAtPath<Material>(path);
            }
            return result;
        }
        private static GameObject GetGroup(string key)
        {
            if (groups.TryGetValue(key, out GameObject result)) return result;
            result = new GameObject(key); groups.Add(key, result);
            if (key.StartsWith("AnnexRoof_", StringComparison.Ordinal))
                result.transform.SetParent(GetGroup("Annex_" + key.Substring("AnnexRoof_".Length)).transform, false);
            else if (key.StartsWith("DISPLAY_", StringComparison.Ordinal))
            {
                MuseumSlotData d = Array.Find(manifest.slots, s => s.geometryGroup == key);
                if (d == null) throw new InvalidDataException("Display group lacks slot metadata: " + key);
                result.transform.SetParent(GetGroup(d.group).transform, false);
                Vector3 basePosition = V(d.position) - Vector3.up * 1.085f;
                result.transform.position = basePosition;
            }
            else result.transform.SetParent(stage.transform, false);
            return result;
        }
        private static MuseumCatalog CreateCatalog()
        {
            List<Chunk> propChunks = ReadGeometry(Root + "/Data/KeepsakeGeometry.bytes");
            List<MuseumMemory> items = new List<MuseumMemory>();
            foreach (IGrouping<string, Chunk> model in propChunks.GroupBy(c => c.group))
            {
                string name = model.Key.StartsWith("PROP_") ? model.Key.Substring(5) : model.Key;
                GameObject root = new GameObject(name);
                foreach (Chunk chunk in model)
                {
                    Mesh mesh = CreateMesh(chunk, "Keepsake_" + chunk.name, false);
                    GameObject child = new GameObject(chunk.name); child.transform.SetParent(root.transform, false);
                    child.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer mr = child.AddComponent<MeshRenderer>(); mr.sharedMaterial = materials[chunk.material];
                    mr.shadowCastingMode = ShadowCastingMode.On;
                }
                string path = Generated + "/Prefabs/Keepsake_" + name + ".prefab";
                GameObject prefab = PrefabUtility.SaveAsPrefabAsset(root, path); UnityEngine.Object.DestroyImmediate(root);
                items.Add(new MuseumMemory { id = name, title = NiceTitle(name),
                    description = "An original procedural sample. Replace its prefab with a 3D model of your own memory.", prefab = prefab });
            }
            MuseumCatalog catalog = ScriptableObject.CreateInstance<MuseumCatalog>();
            catalog.memories = items.ToArray();
            ReplaceAsset(catalog, Generated + "/MuseumCatalog.asset");
            return AssetDatabase.LoadAssetAtPath<MuseumCatalog>(Generated + "/MuseumCatalog.asset");
        }
        private static Dictionary<string, MuseumDisplaySlot> CreateSlots(MuseumCatalog catalog)
        {
            var result = new Dictionary<string, MuseumDisplaySlot>();
            foreach (MuseumSlotData d in manifest.slots)
            {
                GameObject root = new GameObject(d.id + "_Anchor"); root.transform.SetParent(GetGroup(d.geometryGroup).transform, false);
                root.transform.position = V(d.position);
                MuseumDisplaySlot slot = root.AddComponent<MuseumDisplaySlot>();
                slot.slotId = d.id; slot.memoryTitle = d.title; slot.memoryDate = d.date;
                slot.memoryLocation = d.location; slot.memoryNote = d.note; slot.displayVolume = V(d.size);
                BoxCollider trigger = root.AddComponent<BoxCollider>(); trigger.isTrigger = true;
                trigger.center = Vector3.up * d.size[1] * 0.5f; trigger.size = V(d.size);
                MuseumMemory memory = catalog.Find(d.sample);
                if (memory != null) slot.PlacePrefab(memory.prefab, memory.id, d.rotation);
                result.Add(d.id, slot);
            }
            return result;
        }
        private static void CreateColliders(Dictionary<string, MuseumDisplaySlot> slots)
        {
            int index = 0;
            foreach (MuseumColliderData d in manifest.colliders)
            {
                GameObject parent = GetGroup(d.group);
                GameObject go = new GameObject("COL_" + d.name + "_" + index++);
                go.transform.SetParent(parent.transform, false);
                Vector3 offset = parent.transform.position;
                if (d.type == "box")
                {
                    BoxCollider collider = go.AddComponent<BoxCollider>(); collider.center = V(d.center) - offset; collider.size = V(d.size);
                }
                else if (d.type == "mesh")
                {
                    if (d.vertices == null || d.triangles == null || d.vertices.Length % 3 != 0) throw new InvalidDataException("Bad collision mesh.");
                    Mesh mesh = new Mesh { name = go.name };
                    Vector3[] v = new Vector3[d.vertices.Length / 3];
                    for (int i = 0; i < v.Length; i++) v[i] = new Vector3(d.vertices[i * 3], d.vertices[i * 3 + 1], d.vertices[i * 3 + 2]) - offset;
                    mesh.vertices = v; mesh.triangles = d.triangles; mesh.RecalculateNormals(); mesh.RecalculateBounds();
                    string path = Generated + "/Meshes/" + go.name + ".asset"; ReplaceAsset(mesh, path);
                    go.AddComponent<MeshCollider>().sharedMesh = AssetDatabase.LoadAssetAtPath<Mesh>(path);
                }
                if (d.name.StartsWith("SLOT_", StringComparison.Ordinal) && d.name.Length >= 8)
                {
                    string id = d.name.Substring(0, 8);
                    if (slots.TryGetValue(id, out MuseumDisplaySlot slot)) go.AddComponent<MuseumSlotHitTarget>().slot = slot;
                }
            }
        }
        private static void CreateGalleryLights()
        {
            int index = 0;
            foreach (MuseumLightData d in manifest.lights)
            {
                // One broad light per room, not a shadow caster per decorative bulb.
                if (d.kind == "point") continue;
                GameObject go = new GameObject("Light_" + d.name + "_" + index++); go.transform.SetParent(GetGroup(d.group).transform, false);
                go.transform.position = V(d.position); go.transform.rotation = Quaternion.Euler(90, 0, 0);
                Light light = go.AddComponent<Light>(); light.type = LightType.Spot; light.spotAngle = 118;
                light.color = new Color(d.color[0], d.color[1], d.color[2]); light.intensity = d.power;
                light.range = d.range; light.shadows = LightShadows.None; light.lightmapBakeType = LightmapBakeType.Mixed;
            }
        }
        private static GameObject CreateVisitor(out MuseumWalker walker, out Camera camera)
        {
            GameObject visitor = new GameObject("Museum_Visitor"); visitor.transform.position = V(manifest.playerSpawn);
            CharacterController controller = visitor.AddComponent<CharacterController>();
            controller.height = 1.80f; controller.radius = 0.26f; controller.center = new Vector3(0, 0.90f, 0);
            controller.slopeLimit = 50; controller.stepOffset = 0.30f; controller.skinWidth = 0.03f; controller.minMoveDistance = 0;
            GameObject cameraObject = new GameObject("Visitor_Camera"); cameraObject.transform.SetParent(visitor.transform, false);
            cameraObject.transform.localPosition = new Vector3(0, 1.65f, 0); cameraObject.tag = "MainCamera";
            camera = cameraObject.AddComponent<Camera>(); camera.fieldOfView = 68; camera.nearClipPlane = 0.045f;
            camera.farClipPlane = 140; camera.allowHDR = true; camera.allowMSAA = true;
            cameraObject.AddComponent<AudioListener>();
            walker = visitor.AddComponent<MuseumWalker>(); walker.viewCamera = camera; walker.rescuePosition = visitor.transform.position;
            return visitor;
        }
        private static void CreateDaylight(Camera camera)
        {
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.59f, 0.66f, 0.71f);
            RenderSettings.ambientEquatorColor = new Color(0.53f, 0.52f, 0.43f);
            RenderSettings.ambientGroundColor = new Color(0.24f, 0.23f, 0.20f);
            RenderSettings.ambientIntensity = 1.0f; RenderSettings.reflectionIntensity = 0.7f;
            RenderSettings.fog = false;
            GameObject sunObject = new GameObject("Museum_Sun"); sunObject.transform.rotation = Quaternion.Euler(52, -35, 0);
            Light sun = sunObject.AddComponent<Light>(); sun.type = LightType.Directional;
            sun.color = new Color(1, 0.88f, 0.73f); sun.intensity = 1.65f; sun.shadows = LightShadows.Soft;
            sun.shadowStrength = 0.75f; sun.shadowBias = 0.035f; sun.shadowNormalBias = 0.12f;
            RenderSettings.sun = sun;
            Shader skyShader = Shader.Find("Skybox/Procedural");
            if (skyShader != null)
            {
                Material sky = new Material(skyShader) { name = "Lumen_Daylight" };
                sky.SetFloat("_SunSize", 0.025f); sky.SetFloat("_AtmosphereThickness", 0.7f);
                sky.SetColor("_SkyTint", new Color(0.49f, 0.62f, 0.70f)); sky.SetColor("_GroundColor", new Color(0.47f, 0.44f, 0.37f));
                sky.SetFloat("_Exposure", 1.15f); ReplaceAsset(sky, Generated + "/Materials/Lumen_Daylight.mat");
                RenderSettings.skybox = AssetDatabase.LoadAssetAtPath<Material>(Generated + "/Materials/Lumen_Daylight.mat");
            }
            GameObject probeObject = new GameObject("Museum_ReflectionProbe"); probeObject.transform.position = new Vector3(0, 3.8f, 0);
            ReflectionProbe probe = probeObject.AddComponent<ReflectionProbe>(); probe.mode = ReflectionProbeMode.Realtime;
            probe.refreshMode = ReflectionProbeRefreshMode.OnAwake; probe.timeSlicingMode = ReflectionProbeTimeSlicingMode.AllFacesAtOnce;
            probe.resolution = 128; probe.size = new Vector3(27, 10, 30); probe.boxProjection = true;
            probe.intensity = 0.7f; probe.nearClipPlane = 0.2f; probe.farClipPlane = 100;
            camera.clearFlags = CameraClearFlags.Skybox; camera.backgroundColor = new Color(0.56f, 0.72f, 0.82f);
        }
        private static void SavePrefabs(Dictionary<string, MuseumDisplaySlot> slots, MuseumCatalog catalog)
        {
            PrefabUtility.SaveAsPrefabAsset(stage, Generated + "/Prefabs/MemoryMuseum_WithDisplays.prefab");
            foreach (MuseumDisplaySlot s in slots.Values) s.ClearDisplay();
            PrefabUtility.SaveAsPrefabAsset(stage, Generated + "/Prefabs/MemoryMuseum_Empty.prefab");
            foreach (MuseumSlotData d in manifest.slots)
            {
                MuseumMemory memory = catalog.Find(d.sample);
                if (memory != null) slots[d.id].PlacePrefab(memory.prefab, memory.id, d.rotation);
            }
            foreach (string which in new[] { "West", "East" })
            {
                GameObject wing = UnityEngine.Object.Instantiate(GetGroup("Annex_" + which));
                wing.name = "Annex_" + which; wing.transform.SetParent(null); wing.SetActive(true);
                PrefabUtility.SaveAsPrefabAsset(wing, Generated + "/Prefabs/Annex_" + which + ".prefab");
                UnityEngine.Object.DestroyImmediate(wing);
            }
            foreach (string id in new[] { "SLOT_001", "SLOT_004" })
            {
                GameObject display = UnityEngine.Object.Instantiate(GetGroup("DISPLAY_" + id));
                display.name = id == "SLOT_001" ? "DisplayPlinth_GlassCase" : "DisplayPlinth_Open";
                display.transform.SetParent(null); display.transform.position = Vector3.zero;
                MuseumDisplaySlot slot = display.GetComponentInChildren<MuseumDisplaySlot>(true);
                slot.ClearDisplay(); slot.slotId = "ASSIGN_UNIQUE_ID"; slot.memoryTitle = "Your memory";
                PrefabUtility.SaveAsPrefabAsset(display, Generated + "/Prefabs/" + display.name + ".prefab");
                UnityEngine.Object.DestroyImmediate(display);
            }
        }
        private static Mesh CreateMesh(Chunk chunk, string name, bool lightmapUV)
        {
            Mesh mesh = new Mesh { name = name, indexFormat = IndexFormat.UInt32 };
            mesh.vertices = chunk.vertices; mesh.normals = chunk.normals; mesh.uv = chunk.uv; mesh.triangles = chunk.triangles;
            mesh.RecalculateBounds(); mesh.RecalculateTangents();
            MuseumMaterialData material = manifest.materials[chunk.material];
            if (lightmapUV && chunk.vertices.Length < 14000 && material.alpha >= 1 && !material.name.StartsWith("Leaf"))
                Unwrapping.GenerateSecondaryUVSet(mesh);
            string path = Generated + "/Meshes/" + Sanitize(name) + ".asset";
            ReplaceAsset(mesh, path); return AssetDatabase.LoadAssetAtPath<Mesh>(path);
        }
        private static List<Chunk> ReadGeometry(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("Missing geometry payload", path);
            var chunks = new List<Chunk>();
            using (BinaryReader reader = new BinaryReader(File.OpenRead(path), Encoding.UTF8))
            {
                if (Encoding.ASCII.GetString(reader.ReadBytes(8)) != "MUSEUM01") throw new InvalidDataException("Bad geometry header.");
                uint count = reader.ReadUInt32(); if (count > 50000) throw new InvalidDataException("Geometry batch count is invalid.");
                for (int k = 0; k < count; k++)
                {
                    Chunk c = new Chunk { name = ReadString(reader), group = ReadString(reader) };
                    c.material = checked((int)reader.ReadUInt32());
                    int nv = checked((int)reader.ReadUInt32()), nt = checked((int)reader.ReadUInt32());
                    if (nv < 1 || nv > 5000000 || nt < 3 || nt > 30000000 || nt % 3 != 0 || c.material >= manifest.materials.Length)
                        throw new InvalidDataException("Geometry batch dimensions are invalid.");
                    c.vertices = new Vector3[nv]; c.normals = new Vector3[nv]; c.uv = new Vector2[nv]; c.triangles = new int[nt];
                    for (int i = 0; i < nv; i++) c.vertices[i] = ReadV(reader);
                    for (int i = 0; i < nv; i++) c.normals[i] = ReadV(reader);
                    for (int i = 0; i < nv; i++) c.uv[i] = new Vector2(reader.ReadSingle(), reader.ReadSingle());
                    for (int i = 0; i < nt; i++)
                    {
                        c.triangles[i] = checked((int)reader.ReadUInt32());
                        if (c.triangles[i] >= nv) throw new InvalidDataException("Triangle index outside its mesh.");
                    }
                    chunks.Add(c);
                }
                if (reader.BaseStream.Position != reader.BaseStream.Length) throw new InvalidDataException("Unexpected trailing geometry data.");
            }
            return chunks;
        }
        private static string ReadString(BinaryReader reader)
        {
            int length = checked((int)reader.ReadUInt32());
            if (length < 0 || length > 4096) throw new InvalidDataException("Geometry string length is invalid.");
            byte[] bytes = reader.ReadBytes(length); if (bytes.Length != length) throw new EndOfStreamException();
            return Encoding.UTF8.GetString(bytes);
        }
        private static Vector3 ReadV(BinaryReader r) { return new Vector3(r.ReadSingle(), r.ReadSingle(), r.ReadSingle()); }
        private static Vector3 V(float[] v)
        { if (v == null || v.Length != 3) throw new InvalidDataException("Expected a three-component vector."); return new Vector3(v[0], v[1], v[2]); }
        private static string Sanitize(string name) { return new string(name.Select(c => char.IsLetterOrDigit(c) || c == '_' ? c : '_').ToArray()); }
        private static string NiceTitle(string name)
        {
            switch (name)
            {
                case "Shell": return "The coast / a remembered shoreline";
                case "Camera": return "My first camera";
                case "Mug": return "Quiet mornings";
                case "Boat": return "Little voyages";
                case "Teddy": return "A childhood friend";
                case "Vase": return "A vase from that afternoon";
                case "Notebook": return "Field notes";
                default: return "River stones";
            }
        }
        private static void ReplaceAsset(UnityEngine.Object asset, string path)
        {
            UnityEngine.Object old = AssetDatabase.LoadMainAssetAtPath(path);
            if (old != null && old.GetType() == asset.GetType())
            {
                EditorUtility.CopySerialized(asset, old); EditorUtility.SetDirty(old); UnityEngine.Object.DestroyImmediate(asset);
            }
            else
            {
                if (old != null) AssetDatabase.DeleteAsset(path);
                AssetDatabase.CreateAsset(asset, path);
            }
        }
    }
}
