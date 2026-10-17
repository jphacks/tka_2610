using UnityEngine;
#if ENABLE_INPUT_SYSTEM
using UnityEngine.InputSystem;
#endif

namespace LumenMuseum
{
    // Supports either Unity input backend without requiring an Input Actions asset.
    public static class MuseumInput
    {
        public static Vector2 Move
        {
            get
            {
#if ENABLE_INPUT_SYSTEM
                Keyboard k = Keyboard.current;
                if (k == null) return Vector2.zero;
                return new Vector2((k.dKey.isPressed || k.rightArrowKey.isPressed ? 1 : 0) - (k.aKey.isPressed || k.leftArrowKey.isPressed ? 1 : 0),
                    (k.wKey.isPressed || k.upArrowKey.isPressed ? 1 : 0) - (k.sKey.isPressed || k.downArrowKey.isPressed ? 1 : 0));
#else
                return new Vector2((Input.GetKey(KeyCode.D) || Input.GetKey(KeyCode.RightArrow) ? 1 : 0) - (Input.GetKey(KeyCode.A) || Input.GetKey(KeyCode.LeftArrow) ? 1 : 0),
                    (Input.GetKey(KeyCode.W) || Input.GetKey(KeyCode.UpArrow) ? 1 : 0) - (Input.GetKey(KeyCode.S) || Input.GetKey(KeyCode.DownArrow) ? 1 : 0));
#endif
            }
        }
        public static Vector2 Look
        {
            get
            {
#if ENABLE_INPUT_SYSTEM
                return Mouse.current == null ? Vector2.zero : Mouse.current.delta.ReadValue() * 0.09f;
#else
                return new Vector2(Input.GetAxisRaw("Mouse X"), Input.GetAxisRaw("Mouse Y")) * 2f;
#endif
            }
        }
        public static bool Sprint
        {
            get
            {
#if ENABLE_INPUT_SYSTEM
                return Keyboard.current != null && Keyboard.current.leftShiftKey.isPressed;
#else
                return Input.GetKey(KeyCode.LeftShift);
#endif
            }
        }
        public static bool Pressed(char key)
        {
#if ENABLE_INPUT_SYSTEM
            Keyboard k = Keyboard.current;
            if (k == null) return false;
            switch (key)
            {
                case 'e': return k.eKey.wasPressedThisFrame;
                case 'm': return k.mKey.wasPressedThisFrame;
                case 'b': return k.bKey.wasPressedThisFrame;
                case 'h': return k.hKey.wasPressedThisFrame;
                case 'r': return k.rKey.wasPressedThisFrame;
                case 'q': return k.qKey.wasPressedThisFrame;
                case 'x': return k.escapeKey.wasPressedThisFrame;
                default: return false;
            }
#else
            switch (key)
            {
                case 'e': return Input.GetKeyDown(KeyCode.E);
                case 'm': return Input.GetKeyDown(KeyCode.M);
                case 'b': return Input.GetKeyDown(KeyCode.B);
                case 'h': return Input.GetKeyDown(KeyCode.H);
                case 'r': return Input.GetKeyDown(KeyCode.R);
                case 'q': return Input.GetKeyDown(KeyCode.Q);
                case 'x': return Input.GetKeyDown(KeyCode.Escape);
                default: return false;
            }
#endif
        }
        public static bool Click
        {
            get
            {
#if ENABLE_INPUT_SYSTEM
                return Mouse.current != null && Mouse.current.leftButton.wasPressedThisFrame;
#else
                return Input.GetMouseButtonDown(0);
#endif
            }
        }
    }

    [RequireComponent(typeof(CharacterController))]
    public sealed class MuseumWalker : MonoBehaviour
    {
        public Camera viewCamera;
        public float walkSpeed = 2.8f;
        public float fastSpeed = 4.6f;
        public float lookSensitivity = 1f;
        public Vector3 rescuePosition = new Vector3(0, 0.12f, -12.3f);
        public bool Suspended { get; set; }
        private CharacterController controller;
        private float pitch, verticalSpeed;

        private void Awake()
        {
            controller = GetComponent<CharacterController>();
            if (viewCamera == null) viewCamera = GetComponentInChildren<Camera>();
            LockCursor(false); // An explicit click activates navigation; no unexpected pointer capture.
        }
        public void LockCursor(bool locked)
        {
            Cursor.lockState = locked ? CursorLockMode.Locked : CursorLockMode.None;
            Cursor.visible = !locked;
        }
        private void Update()
        {
            if (Suspended || viewCamera == null) return;
            if (MuseumInput.Pressed('x')) LockCursor(false);
            if (MuseumInput.Click && Application.isFocused) LockCursor(true);
            float dt = Mathf.Min(Time.deltaTime, 0.05f);
            Vector2 movement = Cursor.lockState == CursorLockMode.Locked ? Vector2.ClampMagnitude(MuseumInput.Move, 1) : Vector2.zero;
            if (Cursor.lockState == CursorLockMode.Locked)
            {
                Vector2 delta = MuseumInput.Look * lookSensitivity;
                transform.Rotate(0, delta.x, 0, Space.Self);
                pitch = Mathf.Clamp(pitch - delta.y, -82, 82);
                viewCamera.transform.localRotation = Quaternion.Euler(pitch, 0, 0);
            }
            if (controller.isGrounded && verticalSpeed < 0) verticalSpeed = -2f;
            else verticalSpeed = Mathf.Max(verticalSpeed - 18f * dt, -25f);
            Vector3 horizontal = transform.right * movement.x + transform.forward * movement.y;
            controller.Move((horizontal * (MuseumInput.Sprint ? fastSpeed : walkSpeed) + Vector3.up * verticalSpeed) * dt);
            if (transform.position.y < -3f) Rescue();
        }
        public void Rescue()
        {
            controller.enabled = false;
            transform.position = rescuePosition;
            controller.enabled = true;
            verticalSpeed = 0;
        }
        private void OnApplicationFocus(bool focused) { if (!focused) LockCursor(false); }
        private void OnDisable() { LockCursor(false); }
    }
}
