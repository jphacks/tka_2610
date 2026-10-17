using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 画面の向きに合わせて、パネルの配置を切り替える。
/// 横長（PC・スマホ横向き）では右側のパネル、縦長（スマホ縦向き）では下から出るシートにする。
/// 中身はそのままで、RectTransform と CanvasScaler の設定だけを入れ替える。
/// </summary>
[RequireComponent(typeof(RectTransform))]
public class ResponsivePanelLayout : MonoBehaviour
{
    [SerializeField]
    private CanvasScaler canvasScaler;

    [Header("横長のとき（右側のパネル）")]
    [SerializeField]
    private float landscapeWidth = 640f;

    [SerializeField]
    private float landscapeMargin = 32f;

    [SerializeField, Range(0.2f, 1f)]
    private float landscapeHeightRatio = 0.6f;

    [Header("縦長のとき（下からのシート）")]
    [SerializeField, Range(0.2f, 1f)]
    private float portraitHeightRatio = 0.45f;

    [SerializeField]
    private float portraitMargin = 24f;

    // 縦横どちらでも、短い辺が 1080 単位になるようにそろえる。
    // こうすると文字の大きさを縦横で共通にできる。
    private static readonly Vector2 LandscapeReference = new(1920, 1080);
    private static readonly Vector2 PortraitReference = new(1080, 1920);

    private RectTransform rect;
    private int lastWidth;
    private int lastHeight;

    private void Awake()
    {
        rect = GetComponent<RectTransform>();

        if (canvasScaler == null)
        {
            canvasScaler = GetComponentInParent<CanvasScaler>();
        }
    }

    private void OnEnable()
    {
        // 表示し直したときに、閉じている間の画面の変化を反映する
        lastWidth = 0;
        lastHeight = 0;
    }

    private void Update()
    {
        if (Screen.width == lastWidth && Screen.height == lastHeight)
        {
            return;
        }

        lastWidth = Screen.width;
        lastHeight = Screen.height;
        Apply(Screen.height > Screen.width);
    }

    private void Apply(bool portrait)
    {
        if (canvasScaler != null)
        {
            canvasScaler.uiScaleMode =
                CanvasScaler.ScaleMode.ScaleWithScreenSize;
            canvasScaler.screenMatchMode =
                CanvasScaler.ScreenMatchMode.MatchWidthOrHeight;
            canvasScaler.referenceResolution =
                portrait ? PortraitReference : LandscapeReference;
            // 縦長は横幅、横長は高さに合わせる（どちらも短い辺）
            canvasScaler.matchWidthOrHeight = portrait ? 0f : 1f;
        }

        if (portrait)
        {
            rect.anchorMin = new Vector2(0f, 0f);
            rect.anchorMax = new Vector2(1f, portraitHeightRatio);
            rect.pivot = new Vector2(0.5f, 0f);
            rect.offsetMin = new Vector2(portraitMargin, portraitMargin);
            rect.offsetMax = new Vector2(-portraitMargin, 0f);
        }
        else
        {
            // 上下中央に、画面の高さの landscapeHeightRatio 分だけ置く
            float bottom = (1f - landscapeHeightRatio) / 2f;
            rect.anchorMin = new Vector2(1f, bottom);
            rect.anchorMax = new Vector2(1f, 1f - bottom);
            rect.pivot = new Vector2(1f, 0.5f);
            rect.sizeDelta = new Vector2(landscapeWidth, 0f);
            rect.anchoredPosition = new Vector2(-landscapeMargin, 0f);
        }
    }
}