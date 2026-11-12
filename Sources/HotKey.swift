import AppKit
import Carbon.HIToolbox

/// 全局热键管理。
///
/// 用 Carbon 的 RegisterEventHotKey 注册系统级热键：不需要辅助功能权限，
/// 在 Keynote 放映、其它 app 前台时都能触发。默认 ⌃⌥Space，避开设slide
/// 演示常用的空格 / ⌘P / ⌥⌘P，也不和系统 Spotlight（⌘Space）冲突。
final class HotKeyManager {

    static let shared = HotKeyManager()

    /// id → 触发回调
    var handlers: [UInt32: () -> Void] = [:]

    /// 每个热键一个 id：1=开始/暂停，2=设置，3=关于
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// 安装事件处理器（只装一次）
    func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                manager.handlers[hotKeyID.id]?()
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }

    /// 注册（或替换）指定 id 的热键
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        unregister(id: id)
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5452), id: id) // 'CLTR'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { hotKeyRefs[id] = ref }
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs[id] = nil
    }

    // MARK: - 编码转换

    /// NSEvent 修饰键 → Carbon 修饰键
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Carbon 修饰键 → 可读符号（⌃⌥⇧⌘）
    static func modifierSymbols(_ mask: UInt32) -> String {
        var s = ""
        if mask & UInt32(controlKey) != 0 { s += "⌃" }
        if mask & UInt32(optionKey) != 0 { s += "⌥" }
        if mask & UInt32(shiftKey) != 0 { s += "⇧" }
        if mask & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// 常见键的显示名
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // 字母/数字：用当前布局把 keyCode 映射成字符
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return "Key\(keyCode)"
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return "Key\(keyCode)" }
            let text = String(utf16CodeUnits: chars, count: length).uppercased()
            return text.isEmpty ? "Key\(keyCode)" : text
        }
    }

    /// 组合成「⌃⌥Space」
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierSymbols(modifiers) + keyName(keyCode)
    }
}
