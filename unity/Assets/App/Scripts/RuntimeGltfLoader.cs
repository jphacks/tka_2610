using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using UnityEngine;
using GLTFast;
using LumenMuseum;

/// <summary>
/// Rust が配信する作品 GLB を実行時に読み込み、展示台に置く / 外す。
/// 作品を外したときは、もともと置かれていたサンプル展示物に戻す。
/// </summary>
public class RuntimeGltfLoader : MonoBehaviour
{
    public struct ExhibitInfo
    {
        public string id;
        public string modelUrl;
        public string slotId;
        public string title;
        public string childName;
        public string dateLabel;
        public string memo;
        public float yaw;
    }

    private sealed class LoadedExhibit
    {
        public MuseumDisplaySlot slot;
        public GltfImport gltf;
        public GameObject template;

        // 置く前に展示台にあったもの (外したときに戻す)
        public GameObject previousPrefab;
        public string previousItemId;
        public float previousYaw;
        public float previousScale;
        public string previousTitle;
        public string previousDate;
        public string previousLocation;
        public string previousNote;
    }

    [SerializeField]
    private MuseumExperience experience;

    private readonly Dictionary<string, LoadedExhibit> loaded = new();

    private void Awake()
    {
        if (experience == null)
        {
            experience = FindFirstObjectByType<MuseumExperience>();
        }
    }

    public async Task<bool> LoadIntoSlot(ExhibitInfo info)
    {
        if (experience == null)
        {
            Debug.LogError("[GLB] MuseumExperience not found.");
            return false;
        }

        MuseumDisplaySlot targetSlot = FindSlot(info.slotId);

        if (targetSlot == null)
        {
            Debug.LogError(
                $"[GLB] Display slot not found: {info.slotId}"
            );

            return false;
        }

        Debug.Log(
            $"[GLB] Loading {info.modelUrl} -> {info.slotId}"
        );

        var gltf = new GltfImport();

        bool loadedOk;

        try
        {
            loadedOk = await gltf.Load(
                new Uri(info.modelUrl)
            );
        }
        catch (Exception ex)
        {
            Debug.LogError(
                $"[GLB] Load exception: {ex.Message}"
            );

            gltf.Dispose();
            return false;
        }

        if (!loadedOk || this == null)
        {
            Debug.LogError(
                $"[GLB] Load failed: {info.modelUrl}"
            );

            gltf.Dispose();
            return false;
        }

        var templateRoot = new GameObject(
            $"RuntimeTemplate_{info.id}"
        );

        templateRoot.transform.SetParent(
            transform,
            false
        );

        bool instantiated =
            await gltf.InstantiateMainSceneAsync(
                templateRoot.transform
            );

        if (!instantiated)
        {
            Debug.LogError(
                $"[GLB] Instantiate failed: {info.modelUrl}"
            );

            Destroy(templateRoot);
            gltf.Dispose();

            return false;
        }

        // PlacePrefab がこの GameObject を複製して展示する
        templateRoot.SetActive(false);

        // 別館の展示台なら、その棟を開ける
        EnsureSlotVisible(targetSlot);

        var record = new LoadedExhibit
        {
            slot = targetSlot,
            gltf = gltf,
            template = templateRoot,
            previousPrefab = targetSlot.HasContent ? targetSlot.assignedPrefab : null,
            previousItemId = targetSlot.CurrentItemId,
            previousYaw = targetSlot.Yaw,
            previousScale = targetSlot.SizeMultiplier,
            previousTitle = targetSlot.memoryTitle,
            previousDate = targetSlot.memoryDate,
            previousLocation = targetSlot.memoryLocation,
            previousNote = targetSlot.memoryNote,
        };

        // 同じ台に別の作品が残っていたら先に外す
        foreach (var pair in new List<KeyValuePair<string, LoadedExhibit>>(loaded))
        {
            if (pair.Value.slot == targetSlot && pair.Key != info.id)
            {
                Unload(pair.Key);
                record.previousPrefab = targetSlot.HasContent ? targetSlot.assignedPrefab : null;
                record.previousItemId = targetSlot.CurrentItemId;
            }
        }

        bool placed = targetSlot.PlacePrefab(
            templateRoot,
            info.id,
            info.yaw,
            1f
        );

        if (!placed)
        {
            Debug.LogError(
                $"[GLB] Place failed: {info.slotId}"
            );

            Destroy(templateRoot);
            gltf.Dispose();

            return false;
        }

        ApplyInfo(targetSlot, info);

        // Dispose すると Mesh 等まで破棄されるので、外すまで保持する
        loaded[info.id] = record;

        Debug.Log(
            $"[GLB] {info.title} placed in {info.slotId}"
        );

        return true;
    }

    /// <summary>タイトルやメモ、向きだけが変わったとき</summary>
    public void UpdateInfo(ExhibitInfo info)
    {
        if (!loaded.TryGetValue(info.id, out LoadedExhibit item) || item.slot == null)
            return;

        ApplyInfo(item.slot, info);

        float delta = Mathf.DeltaAngle(item.slot.Yaw, info.yaw);
        if (Mathf.Abs(delta) > 0.01f)
            item.slot.RotateBy(delta);
    }

    /// <summary>Web で展示をやめた・削除した作品を外す</summary>
    public void Unload(string exhibitId)
    {
        if (!loaded.Remove(exhibitId, out LoadedExhibit item))
            return;

        MuseumDisplaySlot slot = item.slot;

        if (slot != null && slot.CurrentItemId == exhibitId)
        {
            slot.ClearDisplay();

            if (item.previousPrefab != null)
            {
                slot.PlacePrefab(
                    item.previousPrefab,
                    item.previousItemId,
                    item.previousYaw,
                    item.previousScale
                );
            }

            slot.memoryTitle = item.previousTitle;
            slot.memoryDate = item.previousDate;
            slot.memoryLocation = item.previousLocation;
            slot.memoryNote = item.previousNote;
        }

        if (item.template != null)
            Destroy(item.template);

        item.gltf?.Dispose();

        Debug.Log($"[GLB] Unloaded {exhibitId}");
    }

    private static void ApplyInfo(
        MuseumDisplaySlot slot,
        ExhibitInfo info
    )
    {
        slot.memoryTitle = info.title;
        slot.memoryDate = info.dateLabel ?? "";
        slot.memoryLocation = info.childName ?? "";
        slot.memoryNote = info.memo ?? "";
    }

    private void EnsureSlotVisible(MuseumDisplaySlot slot)
    {
        if (slot.gameObject.activeInHierarchy)
            return;

        MuseumExpansion expansion = experience.expansion;

        if (expansion == null)
            return;

        bool west = slot.transform.position.x < 0f;
        expansion.SetWing(west, true, true);
    }

    private MuseumDisplaySlot FindSlot(
        string slotId
    )
    {
        if (experience.slots == null)
            return null;

        foreach (MuseumDisplaySlot slot in experience.slots)
        {
            if (
                slot != null &&
                slot.slotId == slotId
            )
            {
                return slot;
            }
        }

        return null;
    }

    private void OnDestroy()
    {
        foreach (LoadedExhibit item in loaded.Values)
        {
            item.gltf?.Dispose();
        }

        loaded.Clear();
    }
}
