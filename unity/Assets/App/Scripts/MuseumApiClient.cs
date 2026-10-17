using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Networking;

/// <summary>
/// Rust API (GET /api/exhibits) をポーリングして、Web 画面で「展示する」した作品を
/// 展示台に並べる。Web で展示をやめた・別の台に移した・削除した作品も反映する。
/// 変化が無いときは Rust が 304 を返すので、ポーリングはほぼ無負荷。
/// </summary>
public class MuseumApiClient : MonoBehaviour
{
    [SerializeField]
    private string apiUrl =
        "http://localhost:8080/api/exhibits";

    [SerializeField]
    private float refreshInterval = 2f;

    [SerializeField]
    private RuntimeGltfLoader gltfLoader;

    [Serializable]
    private class ExhibitDto
    {
        public string id;
        public string title;
        public string model_url;
        public string slot_id;
        public string status;
        public int yaw;
        public string child_name;
        public string date_label;
        public string memo;
        public string category;
    }

    [Serializable]
    private class ExhibitList
    {
        public ExhibitDto[] items;
    }

    // Rust が「展示中」と言っている作品
    private Dictionary<string, ExhibitDto> desired = new();

    // 実際に展示台へ置いた作品
    private readonly Dictionary<string, ExhibitDto> applied = new();

    // 読み込み中の作品
    private readonly HashSet<string> loading = new();

    private string etag;

    private IEnumerator Start()
    {
        if (gltfLoader == null)
        {
            gltfLoader =
                FindFirstObjectByType<
                    RuntimeGltfLoader
                >();
        }

        if (gltfLoader == null)
        {
            Debug.LogError(
                "[API] RuntimeGltfLoader not found."
            );

            yield break;
        }

        while (true)
        {
            yield return Poll();

            // 304 のときも毎回照合し、失敗した読み込みを再試行する
            Reconcile();

            yield return new WaitForSeconds(
                refreshInterval
            );
        }
    }

    private IEnumerator Poll()
    {
        using UnityWebRequest request =
            UnityWebRequest.Get(apiUrl);

        request.timeout = 10;

        if (!string.IsNullOrEmpty(etag))
        {
            request.SetRequestHeader(
                "If-None-Match",
                etag
            );
        }

        yield return request.SendWebRequest();

        if (request.responseCode == 304)
        {
            yield break;
        }

        if (
            request.result !=
            UnityWebRequest.Result.Success
        )
        {
            Debug.LogWarning(
                "[API] Request failed: " +
                request.error
            );

            yield break;
        }

        ExhibitList response =
            JsonUtility.FromJson<ExhibitList>(
                "{\"items\":" +
                request.downloadHandler.text +
                "}"
            );

        var next =
            new Dictionary<string, ExhibitDto>();

        if (response?.items != null)
        {
            foreach (ExhibitDto exhibit in response.items)
            {
                if (
                    exhibit == null ||
                    exhibit.status != "ready" ||
                    string.IsNullOrEmpty(exhibit.id) ||
                    string.IsNullOrEmpty(exhibit.model_url) ||
                    string.IsNullOrEmpty(exhibit.slot_id)
                )
                {
                    continue;
                }

                next[exhibit.id] = exhibit;
            }
        }

        desired = next;
        etag = request.GetResponseHeader("ETag");

        Debug.Log(
            $"[API] {desired.Count} exhibits from Rust"
        );
    }

    private static bool NeedsReload(
        ExhibitDto have,
        ExhibitDto want
    )
    {
        return
            have.slot_id != want.slot_id ||
            have.model_url != want.model_url;
    }

    private static bool InfoChanged(
        ExhibitDto have,
        ExhibitDto want
    )
    {
        return
            have.title != want.title ||
            have.memo != want.memo ||
            have.child_name != want.child_name ||
            have.date_label != want.date_label ||
            have.yaw != want.yaw;
    }

    private void Reconcile()
    {
        // 1. 展示をやめた / 台が変わった / モデルが変わった作品を片付ける
        foreach (string id in new List<string>(applied.Keys))
        {
            if (
                !desired.TryGetValue(id, out ExhibitDto want) ||
                NeedsReload(applied[id], want)
            )
            {
                gltfLoader.Unload(id);
                applied.Remove(id);
            }
        }

        // 2. 新しい作品を読み込み、情報だけ変わった作品は更新する
        foreach (ExhibitDto want in desired.Values)
        {
            if (applied.TryGetValue(want.id, out ExhibitDto have))
            {
                if (InfoChanged(have, want))
                {
                    gltfLoader.UpdateInfo(ToInfo(want));
                    applied[want.id] = want;
                }

                continue;
            }

            if (loading.Contains(want.id))
                continue;

            LoadExhibit(want);
        }
    }

    private static RuntimeGltfLoader.ExhibitInfo ToInfo(
        ExhibitDto exhibit
    )
    {
        return new RuntimeGltfLoader.ExhibitInfo
        {
            id = exhibit.id,
            modelUrl = exhibit.model_url,
            slotId = exhibit.slot_id,
            title = exhibit.title,
            childName = exhibit.child_name,
            dateLabel = exhibit.date_label,
            memo = exhibit.memo,
            yaw = exhibit.yaw,
        };
    }

    private async void LoadExhibit(
        ExhibitDto exhibit
    )
    {
        loading.Add(exhibit.id);

        bool success;

        try
        {
            success =
                await gltfLoader.LoadIntoSlot(
                    ToInfo(exhibit)
                );
        }
        catch (Exception ex)
        {
            Debug.LogException(ex);
            success = false;
        }
        finally
        {
            loading.Remove(exhibit.id);
        }

        if (!success)
        {
            // 次のポーリングで再試行される
            return;
        }

        applied[exhibit.id] = exhibit;

        // 読み込み中に Web 側で展示が変わっていたら、すぐ反映し直す
        if (
            !desired.TryGetValue(exhibit.id, out ExhibitDto want) ||
            NeedsReload(exhibit, want) ||
            InfoChanged(exhibit, want)
        )
        {
            Reconcile();
        }
    }
}
