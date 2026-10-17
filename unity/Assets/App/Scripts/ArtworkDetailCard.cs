using LumenMuseum;
using TMPro;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 展示台の作品の詳細カード。E キーで開き、開いている間は移動と操作の表示を止める。
/// 表示する内容は RuntimeGltfLoader が展示台に書き込んだもの（タイトル・制作者・日付・メモ）。
/// </summary>
public class ArtworkDetailCard : MonoBehaviour
{
    [SerializeField]
    private MuseumExperience experience;

    [SerializeField]
    private MuseumWalker walker;

    // カードの一番外側（ItemDetailScreen）。ResponsivePanelLayout もここに付ける
    [SerializeField]
    private GameObject cardRoot;

    [SerializeField]
    private TMP_Text titleText;

    [SerializeField]
    private TMP_Text creatorText;

    [SerializeField]
    private TMP_Text dateText;

    [SerializeField]
    private TMP_Text noteText;

    [SerializeField]
    private Button closeButton;

    // カードを開いている間は隠すもの（スマホのスティックなど）
    [SerializeField]
    private GameObject[] hideWhileOpen;

    public bool IsOpen => cardRoot != null && cardRoot.activeSelf;

    private void Awake()
    {
        if (cardRoot != null)
        {
            cardRoot.SetActive(false);
        }

        if (closeButton != null)
        {
            closeButton.onClick.AddListener(Close);
        }
    }

    private void OnEnable()
    {
        if (experience != null)
        {
            experience.ExhibitSelected += Open;
        }
    }

    private void OnDisable()
    {
        if (experience != null)
        {
            experience.ExhibitSelected -= Open;
        }
    }

    private void Update()
    {
        if (IsOpen && MuseumInput.Pressed('x'))
        {
            Close();
        }
    }

    public void Open(MuseumDisplaySlot slot)
    {
        if (slot == null || cardRoot == null)
        {
            return;
        }

        SetText(titleText, slot.memoryTitle);
        // memoryLocation には制作者の名前（child_name）が入っている
        SetText(creatorText, slot.memoryLocation);
        SetText(dateText, slot.memoryDate);
        SetText(noteText, slot.memoryNote);

        cardRoot.SetActive(true);
        SetHidden(true);
    }

    public void Close()
    {
        if (cardRoot != null)
        {
            cardRoot.SetActive(false);
        }

        SetHidden(false);
    }

    private void SetHidden(bool open)
    {
        if (hideWhileOpen != null)
        {
            foreach (GameObject go in hideWhileOpen)
            {
                if (go != null)
                {
                    go.SetActive(!open);
                }
            }
        }

        if (experience != null)
        {
            experience.ExternalPanelOpen = open;
        }

        if (walker != null)
        {
            walker.Suspended = open;
            walker.LockCursor(!open);
        }
    }

    // 空の項目は、行ごと隠す
    private static void SetText(TMP_Text text, string value)
    {
        if (text == null)
        {
            return;
        }

        bool has = !string.IsNullOrEmpty(value);
        text.gameObject.SetActive(has);
        text.text = has ? value : "";
    }
}
