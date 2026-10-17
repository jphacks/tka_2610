using System;
using System.IO;
using UnityEngine;

namespace LumenMuseum
{
    [Serializable]
    public sealed class MuseumSlotSave
    {
        public string slotId, itemId, title, date, location, note;
        public float yaw, scale;
    }
    [Serializable]
    public sealed class MuseumLayoutSave
    {
        public int version = 1;
        public bool westOpen, eastOpen;
        public MuseumSlotSave[] slots;
    }

    [DefaultExecutionOrder(-50)]
    public sealed class MuseumExperience : MonoBehaviour
    {
        public MuseumCatalog catalog;
        public MuseumDisplaySlot[] slots;
        public MuseumWalker walker;
        public MuseumExpansion expansion;
        public MuseumViewMode viewMode;
        public float interactionDistance = 3.4f;
        // 外のパネル（作品カードなど）が使う。登録されていれば、E キーで Curate の代わりにこちらを呼ぶ
        public event Action<MuseumDisplaySlot> ExhibitSelected;
        // 外のパネルを開いている間は true にする。キー操作と画面表示を止める
        public bool ExternalPanelOpen { get; set; }
        public bool autoSave = true;
        private MuseumDisplaySlot hoverSlot, editedSlot;
        private enum Panel { None, Exhibit, Expansion }
        private Panel panel;
        private int selectedCatalogIndex;
        private Vector2 catalogScroll;
        private bool showHud = true, dirty, restoring, confirmReset;
        private float lastChange, toastUntil;
        private string toast = "";
        private MuseumLayoutSave initialLayout;
        private GUIStyle headingStyle, bodyStyle, captionStyle, buttonStyle;
        private string SavePath { get { return Path.Combine(Application.persistentDataPath, "lumen-museum-layout-v1.json"); } }

        private void Start()
        {
            if (slots == null) slots = Array.Empty<MuseumDisplaySlot>();
            initialLayout = CaptureLayout();
            if (expansion != null) expansion.Changed += MarkChanged;
            LoadLayout();
        }
        private void Update()
        {
            if (walker == null) return;
            if (ExternalPanelOpen) { hoverSlot = null; return; }
            if (MuseumInput.Pressed('h')) showHud = !showHud;
            if (MuseumInput.Pressed('x'))
            {
                if (panel != Panel.None) ClosePanel();
                else if (viewMode != null && viewMode.IsOverview) viewMode.SetOverview(false);
                else walker.LockCursor(false);
            }
            if (MuseumInput.Pressed('m'))
            {
                ClosePanel();
                if (viewMode != null) viewMode.SetOverview(!viewMode.IsOverview);
            }
            if (MuseumInput.Pressed('b'))
            {
                if (panel == Panel.Expansion) ClosePanel();
                else OpenPanel(Panel.Expansion);
            }
            bool browsing = panel == Panel.None && (viewMode == null || !viewMode.IsOverview);
            hoverSlot = browsing ? FindLookedAtSlot() : null;
            if (browsing && MuseumInput.Pressed('e') && hoverSlot != null)
            {
                if (ExhibitSelected != null) ExhibitSelected(hoverSlot);
                else { editedSlot = hoverSlot; OpenPanel(Panel.Exhibit); }
            }
            if (dirty && autoSave && Time.unscaledTime - lastChange > 0.8f) SaveLayout();
        }

        private MuseumDisplaySlot FindLookedAtSlot()
        {
            if (walker.viewCamera == null) return null;
            Transform cameraTransform = walker.viewCamera.transform;
            RaycastHit[] hits = Physics.RaycastAll(cameraTransform.position, cameraTransform.forward,
                interactionDistance, ~0, QueryTriggerInteraction.Collide);
            Array.Sort(hits, (a, b) => a.distance.CompareTo(b.distance));
            foreach (RaycastHit hit in hits)
            {
                MuseumSlotHitTarget target = hit.collider.GetComponent<MuseumSlotHitTarget>();
                if (target != null && target.slot != null) return target.slot;
                MuseumDisplaySlot slot = hit.collider.GetComponentInParent<MuseumDisplaySlot>();
                if (slot != null) return slot;
                if (!hit.collider.isTrigger) break; // Do not select exhibits through walls.
            }
            return null;
        }
        private void OpenPanel(Panel newPanel)
        {
            if (viewMode != null && viewMode.IsOverview) viewMode.SetOverview(false);
            panel = newPanel; walker.Suspended = true; walker.LockCursor(false);
        }
        private void ClosePanel()
        {
            panel = Panel.None; editedSlot = null; confirmReset = false;
            if (walker != null)
            {
                walker.Suspended = viewMode != null && viewMode.IsOverview;
                if (!walker.Suspended) walker.LockCursor(true);
            }
        }
        private void MarkChanged()
        {
            if (restoring) return;
            dirty = true; lastChange = Time.unscaledTime;
        }
        private void Notify(string text) { toast = text; toastUntil = Time.unscaledTime + 4f; }

        public MuseumLayoutSave CaptureLayout()
        {
            MuseumLayoutSave state = new MuseumLayoutSave();
            state.westOpen = expansion != null && expansion.WestOpen;
            state.eastOpen = expansion != null && expansion.EastOpen;
            state.slots = new MuseumSlotSave[slots == null ? 0 : slots.Length];
            for (int i = 0; i < state.slots.Length; i++)
            {
                MuseumDisplaySlot s = slots[i];
                if (s == null) continue;
                state.slots[i] = new MuseumSlotSave { slotId = s.slotId, itemId = s.CurrentItemId,
                    title = s.memoryTitle, date = s.memoryDate, location = s.memoryLocation, note = s.memoryNote,
                    yaw = s.Yaw, scale = s.SizeMultiplier };
            }
            return state;
        }
        public void SaveLayout()
        {
            try
            {
                Directory.CreateDirectory(Application.persistentDataPath);
                string temporaryPath = SavePath + ".tmp";
                File.WriteAllText(temporaryPath, JsonUtility.ToJson(CaptureLayout(), true));
                if (File.Exists(SavePath))
                {
                    try { File.Replace(temporaryPath, SavePath, null); }
                    catch (PlatformNotSupportedException) { File.Copy(temporaryPath, SavePath, true); File.Delete(temporaryPath); }
                    catch (IOException) { File.Copy(temporaryPath, SavePath, true); File.Delete(temporaryPath); }
                }
                else File.Move(temporaryPath, SavePath);
                dirty = false;
                Notify("Layout saved locally.");
            }
            catch (Exception ex) { dirty = false; Notify("Save failed: " + ex.Message); Debug.LogWarning(ex, this); }
        }
        private void LoadLayout()
        {
            if (!File.Exists(SavePath)) return;
            try
            {
                MuseumLayoutSave state = JsonUtility.FromJson<MuseumLayoutSave>(File.ReadAllText(SavePath));
                if (state == null || state.version != 1 || state.slots == null) { Notify("Unsupported layout file; using scene defaults."); return; }
                ApplyLayout(state);
            }
            catch (Exception ex) { Notify("Could not load layout; scene defaults kept."); Debug.LogWarning(ex, this); }
        }
        private void ApplyLayout(MuseumLayoutSave state)
        {
            restoring = true;
            try
            {
                if (expansion != null)
                {
                    expansion.SetWing(true, state.westOpen, true);
                    expansion.SetWing(false, state.eastOpen, true);
                }
                foreach (MuseumSlotSave record in state.slots)
                {
                    if (record == null || string.IsNullOrEmpty(record.slotId)) continue;
                    MuseumDisplaySlot slot = Array.Find(slots, s => s != null && s.slotId == record.slotId);
                    if (slot == null) continue;
                    if (string.IsNullOrEmpty(record.itemId)) slot.ClearDisplay();
                    else
                    {
                        MuseumMemory memory = catalog == null ? null : catalog.Find(record.itemId);
                        // Missing external catalog entries do not destroy the existing scene content.
                        if (memory != null && memory.prefab != null)
                            slot.PlacePrefab(memory.prefab, memory.id, record.yaw, record.scale);
                    }
                    slot.memoryTitle = record.title ?? "Your memory";
                    slot.memoryDate = record.date ?? "";
                    slot.memoryLocation = record.location ?? "";
                    slot.memoryNote = record.note ?? "";
                }
            }
            finally { restoring = false; dirty = false; }
        }
        private void OnApplicationQuit() { if (dirty && autoSave) SaveLayout(); }
        private void OnDestroy() { if (expansion != null) expansion.Changed -= MarkChanged; }

        private void EnsureStyles()
        {
            if (headingStyle != null) return;
            headingStyle = new GUIStyle(GUI.skin.label) { fontSize = 24, fontStyle = FontStyle.Bold, wordWrap = true };
            headingStyle.normal.textColor = new Color(0.92f, 0.89f, 0.80f);
            bodyStyle = new GUIStyle(GUI.skin.label) { fontSize = 14, wordWrap = true };
            bodyStyle.normal.textColor = new Color(0.92f, 0.93f, 0.89f);
            captionStyle = new GUIStyle(bodyStyle) { fontSize = 12 };
            captionStyle.normal.textColor = new Color(0.66f, 0.76f, 0.73f);
            buttonStyle = new GUIStyle(GUI.skin.button) { fontSize = 14, padding = new RectOffset(10, 10, 9, 9), wordWrap = true };
        }
        private static void FillPanel(Rect rectangle, float opacity = 0.94f)
        {
            Color old = GUI.color;
            GUI.color = new Color(0.065f, 0.105f, 0.108f, opacity);
            GUI.DrawTexture(rectangle, Texture2D.whiteTexture);
            GUI.color = old;
        }
        private void OnGUI()
        {
            if (ExternalPanelOpen) return;
            EnsureStyles();
            if (!showHud && panel == Panel.None) return;
            if (panel == Panel.None)
            {
                FillPanel(new Rect(22, 22, 310, 83), 0.86f);
                GUI.Label(new Rect(38, 32, 285, 33), "LUMEN / MEMORY MUSEUM", bodyStyle);
                GUI.Label(new Rect(38, 65, 280, 30), viewMode != null && viewMode.IsOverview ? "Ground-floor cutaway  /  M to return" : "A place for memories in three dimensions.", captionStyle);
                string controls = "WASD  walk   /   Mouse  look   /   Shift  faster\nE  curate   /   M  museum map   /   B  add rooms\nEsc  release pointer   /   H  hide interface";
                FillPanel(new Rect(22, Screen.height - 110, 405, 88), 0.83f);
                GUI.Label(new Rect(38, Screen.height - 98, 378, 76), controls, bodyStyle);
                if (hoverSlot != null)
                {
                    FillPanel(new Rect(Screen.width / 2f - 160, Screen.height - 160, 320, 44), 0.88f);
                    GUI.Label(new Rect(Screen.width / 2f - 147, Screen.height - 151, 300, 32), "E  /  " + hoverSlot.memoryTitle, bodyStyle);
                }
                if (walker != null && !walker.Suspended)
                {
                    if (Cursor.lockState == CursorLockMode.Locked)
                        GUI.Label(new Rect(Screen.width / 2f - 4, Screen.height / 2f - 10, 16, 20), "+", bodyStyle);
                    else GUI.Label(new Rect(Screen.width / 2f - 150, Screen.height - 52, 320, 28), "Click the view to begin walking.", bodyStyle);
                }
            }
            else
            {
                float width = Mathf.Min(450, Screen.width - 32);
                Rect area = new Rect(Screen.width - width - 16, 16, width, Screen.height - 32);
                FillPanel(area);
                GUILayout.BeginArea(new Rect(area.x + 20, area.y + 18, area.width - 40, area.height - 36));
                if (panel == Panel.Exhibit && editedSlot != null) DrawExhibitPanel();
                else if (panel == Panel.Expansion) DrawExpansionPanel();
                GUILayout.EndArea();
            }
            if (Time.unscaledTime < toastUntil)
            {
                FillPanel(new Rect(Screen.width / 2f - 235, 20, 470, 42), 0.95f);
                GUI.Label(new Rect(Screen.width / 2f - 223, 30, 446, 28), toast, bodyStyle);
            }
        }
        private void DrawExhibitPanel()
        {
            GUILayout.Label("Curate a memory", headingStyle);
            GUILayout.Label(editedSlot.slotId + "  /  real 3D display", captionStyle);
            GUILayout.Space(12);
            string title = GUILayout.TextField(editedSlot.memoryTitle ?? "", 120);
            string note = GUILayout.TextArea(editedSlot.memoryNote ?? "", 1200, GUILayout.Height(60));
            if (title != editedSlot.memoryTitle || note != editedSlot.memoryNote)
            { editedSlot.memoryTitle = title; editedSlot.memoryNote = note; MarkChanged(); }
            GUILayout.Space(10);
            GUILayout.Label("Choose a model from your catalog", bodyStyle);
            catalogScroll = GUILayout.BeginScrollView(catalogScroll, GUILayout.Height(Mathf.Max(110, Mathf.Min(250, Screen.height - 430))));
            if (catalog != null && catalog.memories != null)
            {
                for (int i = 0; i < catalog.memories.Length; i++)
                {
                    MuseumMemory memory = catalog.memories[i];
                    if (memory == null) continue;
                    string text = (i == selectedCatalogIndex ? ">  " : "   ") + memory.title;
                    if (GUILayout.Button(text, buttonStyle)) selectedCatalogIndex = i;
                }
            }
            GUILayout.EndScrollView();
            if (GUILayout.Button("Place selected 3D model", buttonStyle))
            {
                if (catalog != null && catalog.memories != null && selectedCatalogIndex >= 0 && selectedCatalogIndex < catalog.memories.Length)
                {
                    MuseumMemory memory = catalog.memories[selectedCatalogIndex];
                    if (memory != null && editedSlot.PlacePrefab(memory.prefab, memory.id))
                    { editedSlot.memoryTitle = memory.title; editedSlot.memoryNote = memory.description; MarkChanged(); }
                }
            }
            GUILayout.BeginHorizontal();
            if (GUILayout.Button("Rotate -15", buttonStyle)) { editedSlot.RotateBy(-15); MarkChanged(); }
            if (GUILayout.Button("Rotate +15", buttonStyle)) { editedSlot.RotateBy(15); MarkChanged(); }
            GUILayout.EndHorizontal();
            GUILayout.Label("Scale within the display volume", captionStyle);
            float scale = GUILayout.HorizontalSlider(editedSlot.SizeMultiplier, 0.2f, 1f);
            if (!Mathf.Approximately(scale, editedSlot.SizeMultiplier)) { editedSlot.SetSize(scale); MarkChanged(); }
            GUILayout.BeginHorizontal();
            if (GUILayout.Button("Clear display", buttonStyle)) { editedSlot.ClearDisplay(); MarkChanged(); }
            if (GUILayout.Button("Save layout", buttonStyle)) SaveLayout();
            GUILayout.EndHorizontal();
            GUILayout.Space(8);
            GUILayout.Label("Add your own prefab to MuseumCatalog in the Inspector. This demo does not upload or scan personal data.", captionStyle);
            if (GUILayout.Button("Return to the museum  /  Esc", buttonStyle)) ClosePanel();
        }
        private void DrawExpansionPanel()
        {
            GUILayout.Label("Room to remember", headingStyle);
            GUILayout.Label("Two independent, walkable gallery wings.", bodyStyle);
            GUILayout.Space(20);
            if (expansion != null)
            {
                GUILayout.Label("WEST / FAMILY GALLERY", bodyStyle);
                GUILayout.Label("Three display plinths, arched windows, oak floor.\nConnected by a real doorway to the west gallery.", captionStyle);
                if (GUILayout.Button(expansion.WestOpen ? "Close west wing" : "Add west wing", buttonStyle))
                    if (!expansion.SetWing(true, !expansion.WestOpen)) Notify("Return to the main museum before removing this room.");
                GUILayout.Space(22);
                GUILayout.Label("EAST / TRAVEL GALLERY", bodyStyle);
                GUILayout.Label("Three more display positions and a quiet daylight gallery.", captionStyle);
                if (GUILayout.Button(expansion.EastOpen ? "Close east wing" : "Add east wing", buttonStyle))
                    if (!expansion.SetWing(false, !expansion.EastOpen)) Notify("Return to the main museum before removing this room.");
            }
            GUILayout.Space(24);
            if (GUILayout.Button("View the floor plan", buttonStyle)) { ClosePanel(); if (viewMode != null) viewMode.SetOverview(true); }
            if (GUILayout.Button("Save layout", buttonStyle)) SaveLayout();
            GUILayout.Space(14);
            if (GUILayout.Button(confirmReset ? "Confirm reset to supplied layout" : "Reset demo layout...", buttonStyle))
            {
                if (!confirmReset) confirmReset = true;
                else if (initialLayout != null)
                {
                    if (walker != null) walker.Rescue();
                    ApplyLayout(initialLayout); MarkChanged(); SaveLayout(); confirmReset = false;
                    Notify("Demo layout restored.");
                }
            }
            GUILayout.Label("Only this demo's local layout is saved. No account, network service, or API key is needed.", captionStyle);
            GUILayout.Space(18);
            if (GUILayout.Button("Return to the museum  /  Esc", buttonStyle)) ClosePanel();
        }
    }
}
