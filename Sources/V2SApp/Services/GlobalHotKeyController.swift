import Carbon.HIToolbox
import Combine
import Foundation

private let globalHotKeyEventSignature = OSType(0x56325320) // "V2S "

enum GlobalHotKeyAction: UInt32, CaseIterable, Hashable, Sendable {
    case followUp = 1
    case ask = 2
    case switchMode = 3
}

struct HotKeyRegistrationPlan: Equatable {
    let bindings: [GlobalHotKeyAction: HotKeyBinding]
    let errors: [GlobalHotKeyAction: HotKeyRegistrationError]
}

enum HotKeyRegistrationError: Equatable, Hashable {
    case invalidBinding
    case duplicateBinding
    case registrationFailed(OSStatus)
}

struct GlobalHotKeyRegistration {
    let action: GlobalHotKeyAction
    fileprivate let reference: EventHotKeyRef?

    init(action: GlobalHotKeyAction) {
        self.action = action
        self.reference = nil
    }

    fileprivate init(action: GlobalHotKeyAction, reference: EventHotKeyRef) {
        self.action = action
        self.reference = reference
    }
}

struct GlobalHotKeyEventHandlerInstallation {
    fileprivate let reference: EventHandlerRef?

    init() {
        reference = nil
    }

    fileprivate init(reference: EventHandlerRef) {
        self.reference = reference
    }
}

struct HotKeySystemRegistrationFailure: Error, Equatable {
    let status: OSStatus
}

protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: GlobalHotKeyAction
    ) -> Result<GlobalHotKeyRegistration, HotKeySystemRegistrationFailure>
    func unregister(_ registration: GlobalHotKeyRegistration)
}

protocol GlobalHotKeyEventInstalling: AnyObject {
    func install(
        userData: UnsafeMutableRawPointer
    ) -> Result<GlobalHotKeyEventHandlerInstallation, HotKeySystemRegistrationFailure>
    func remove(_ installation: GlobalHotKeyEventHandlerInstallation)
}

@MainActor
final class GlobalHotKeyController: ObservableObject {
    // Carbon virtual key codes for an ANSI alphanumeric keyboard layout.
    static let keyCodeMap: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
        "k": 0x28, "n": 0x2D, "m": 0x2E,
    ]

    nonisolated static let eventSignature = globalHotKeyEventSignature

    @Published private(set) var errors: [GlobalHotKeyAction: HotKeyRegistrationError] = [:]

    private let onAction: (GlobalHotKeyAction) -> Void
    private let registrar: any GlobalHotKeyRegistering
    private let eventInstaller: any GlobalHotKeyEventInstalling
    private var registrations: [GlobalHotKeyAction: ActiveHotKeyRegistration] = [:]
    private var eventHandlerInstallation: GlobalHotKeyEventHandlerInstallation?
    private var eventHandlerFailure: OSStatus?

    init(
        onAction: @escaping (GlobalHotKeyAction) -> Void,
        registrar: (any GlobalHotKeyRegistering)? = nil,
        eventInstaller: (any GlobalHotKeyEventInstalling)? = nil,
        installsEventHandler: Bool = true
    ) {
        self.onAction = onAction
        self.registrar = registrar ?? CarbonGlobalHotKeyRegistrar()
        self.eventInstaller = eventInstaller ?? CarbonGlobalHotKeyEventInstaller()
        if installsEventHandler {
            installEventHandler()
        }
    }

    deinit {
        for activeRegistration in registrations.values {
            registrar.unregister(activeRegistration.registration)
        }
        if let eventHandlerInstallation {
            eventInstaller.remove(eventHandlerInstallation)
        }
    }

    func update(followUp: HotKeyBinding, ask: HotKeyBinding, switchMode: HotKeyBinding) {
        let plan = Self.makePlan(
            followUp: followUp,
            ask: ask,
            switchMode: switchMode
        )
        errors = plan.errors

        if let eventHandlerFailure {
            for action in plan.bindings.keys {
                errors[action] = .registrationFailed(eventHandlerFailure)
            }
            return
        }

        for action in GlobalHotKeyAction.allCases {
            let binding = plan.bindings[action]
            if let binding,
               registrations[action]?.binding == NormalizedHotKeyBinding(binding) {
                continue
            }

            if let activeRegistration = registrations.removeValue(forKey: action) {
                registrar.unregister(activeRegistration.registration)
            }

            guard let binding,
                  let keyCode = Self.keyCodeMap[binding.normalizedKey] else {
                continue
            }

            switch registrar.register(
                keyCode: keyCode,
                modifiers: Self.carbonModifiers(for: binding),
                action: action
            ) {
            case .success(let registration):
                registrations[action] = ActiveHotKeyRegistration(
                    binding: NormalizedHotKeyBinding(binding),
                    registration: registration
                )
            case .failure(let failure):
                errors[action] = .registrationFailed(failure.status)
            }
        }
    }

    func invalidate() {
        unregisterAll()
        removeEventHandler()
        errors = [:]
    }

    static func makePlan(
        followUp: HotKeyBinding,
        ask: HotKeyBinding,
        switchMode: HotKeyBinding
    ) -> HotKeyRegistrationPlan {
        let candidates: [(GlobalHotKeyAction, HotKeyBinding)] = [
            (.followUp, followUp),
            (.ask, ask),
            (.switchMode, switchMode),
        ]
        var errors: [GlobalHotKeyAction: HotKeyRegistrationError] = [:]
        var actionsByBinding: [NormalizedHotKeyBinding: [GlobalHotKeyAction]] = [:]

        for (action, binding) in candidates {
            guard binding.isValid else {
                errors[action] = .invalidBinding
                continue
            }
            actionsByBinding[NormalizedHotKeyBinding(binding), default: []].append(action)
        }

        for actions in actionsByBinding.values where actions.count > 1 {
            for action in actions {
                errors[action] = .duplicateBinding
            }
        }

        var bindings: [GlobalHotKeyAction: HotKeyBinding] = [:]
        for (action, binding) in candidates where errors[action] == nil {
            bindings[action] = binding
        }
        return HotKeyRegistrationPlan(bindings: bindings, errors: errors)
    }

    nonisolated static func action(for hotKeyID: EventHotKeyID) -> GlobalHotKeyAction? {
        guard hotKeyID.signature == eventSignature else {
            return nil
        }
        return GlobalHotKeyAction(rawValue: hotKeyID.id)
    }

    private func installEventHandler() {
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        switch eventInstaller.install(userData: userData) {
        case .success(let installation):
            eventHandlerInstallation = installation
        case .failure(let failure):
            eventHandlerFailure = failure.status
        }
    }

    private func removeEventHandler() {
        guard let eventHandlerInstallation else {
            return
        }
        eventInstaller.remove(eventHandlerInstallation)
        self.eventHandlerInstallation = nil
    }

    private func unregisterAll() {
        for action in GlobalHotKeyAction.allCases {
            guard let activeRegistration = registrations.removeValue(forKey: action) else {
                continue
            }
            registrar.unregister(activeRegistration.registration)
        }
    }

    fileprivate func handle(hotKeyID: EventHotKeyID) {
        guard let action = Self.action(for: hotKeyID) else {
            return
        }
        onAction(action)
    }

    private static func carbonModifiers(for binding: HotKeyBinding) -> UInt32 {
        var modifiers: UInt32 = 0
        if binding.useCommand { modifiers |= UInt32(cmdKey) }
        if binding.useOption { modifiers |= UInt32(optionKey) }
        if binding.useControl { modifiers |= UInt32(controlKey) }
        if binding.useShift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

private struct ActiveHotKeyRegistration {
    let binding: NormalizedHotKeyBinding
    let registration: GlobalHotKeyRegistration
}

@MainActor
final class AssistantHotKeyRegistrationErrorBridge {
    private weak var assistant: AssistantCoordinator?
    private var errorsCancellable: AnyCancellable?

    init(controller: GlobalHotKeyController, assistant: AssistantCoordinator) {
        self.assistant = assistant
        errorsCancellable = controller.$errors
            .sink { [weak assistant] errors in
                assistant?.updateHotKeyRegistrationErrors(errors)
            }
    }

    func invalidate() {
        errorsCancellable?.cancel()
        errorsCancellable = nil
        assistant?.updateHotKeyRegistrationErrors([:])
    }

    deinit {
        errorsCancellable?.cancel()
    }
}

private struct NormalizedHotKeyBinding: Hashable {
    let key: String
    let useCommand: Bool
    let useOption: Bool
    let useControl: Bool
    let useShift: Bool

    init(_ binding: HotKeyBinding) {
        key = binding.normalizedKey
        useCommand = binding.useCommand
        useOption = binding.useOption
        useControl = binding.useControl
        useShift = binding.useShift
    }
}

private final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: GlobalHotKeyAction
    ) -> Result<GlobalHotKeyRegistration, HotKeySystemRegistrationFailure> {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyController.eventSignature,
            id: action.rawValue
        )
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(.init(status: status == noErr ? OSStatus(-1) : status))
        }
        return .success(GlobalHotKeyRegistration(action: action, reference: reference))
    }

    func unregister(_ registration: GlobalHotKeyRegistration) {
        guard let reference = registration.reference else {
            return
        }
        UnregisterEventHotKey(reference)
    }
}

private final class CarbonGlobalHotKeyEventInstaller: GlobalHotKeyEventInstalling {
    func install(
        userData: UnsafeMutableRawPointer
    ) -> Result<GlobalHotKeyEventHandlerInstallation, HotKeySystemRegistrationFailure> {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonGlobalHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(.init(status: status == noErr ? OSStatus(-1) : status))
        }
        return .success(GlobalHotKeyEventHandlerInstallation(reference: reference))
    }

    func remove(_ installation: GlobalHotKeyEventHandlerInstallation) {
        guard let reference = installation.reference else {
            return
        }
        RemoveEventHandler(reference)
    }
}

private let carbonGlobalHotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == globalHotKeyEventSignature else {
        return status == noErr ? noErr : status
    }

    let controller = Unmanaged<GlobalHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor [weak controller] in
        controller?.handle(hotKeyID: hotKeyID)
    }
    return noErr
}
