import Carbon.HIToolbox
import Testing
@testable import v2s

@MainActor
@Suite struct GlobalHotKeyControllerTests {
    @Test func plannerRegistersThreeUniqueDefaults() {
        let plan = GlobalHotKeyController.makePlan(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )

        #expect(plan.bindings == [
            .followUp: .defaultFollowUp,
            .ask: .defaultAsk,
            .switchMode: .defaultSwitchMode,
        ])
        #expect(plan.errors.isEmpty)
    }

    @Test func plannerRejectsUnmodifiedUnknownAndMultiCharacterKeys() {
        let noModifier = binding(key: "f")
        let unknownKey = binding(key: "?")
        let multipleCharacters = binding(key: "ab")

        let plan = GlobalHotKeyController.makePlan(
            followUp: noModifier,
            ask: unknownKey,
            switchMode: multipleCharacters
        )

        #expect(plan.bindings.isEmpty)
        #expect(plan.errors == [
            .followUp: .invalidBinding,
            .ask: .invalidBinding,
            .switchMode: .invalidBinding,
        ])
    }

    @Test func plannerRejectsBothActionsInADuplicateAndKeepsAnUnrelatedBinding() {
        let duplicate = binding(key: "F", command: true)
        let distinct = binding(key: "g", option: true)

        let plan = GlobalHotKeyController.makePlan(
            followUp: duplicate,
            ask: binding(key: "f", command: true),
            switchMode: distinct
        )

        #expect(plan.bindings == [.switchMode: distinct])
        #expect(plan.errors == [
            .followUp: .duplicateBinding,
            .ask: .duplicateBinding,
        ])
    }

    @Test func plannerRejectsEveryActionInAThreeWayDuplicate() {
        let duplicate = binding(key: "t", command: true, option: true)

        let plan = GlobalHotKeyController.makePlan(
            followUp: duplicate,
            ask: binding(key: "T", command: true, option: true),
            switchMode: duplicate
        )

        #expect(plan.bindings.isEmpty)
        #expect(plan.errors == [
            .followUp: .duplicateBinding,
            .ask: .duplicateBinding,
            .switchMode: .duplicateBinding,
        ])
    }

    @Test func plannerTreatsSameKeyWithDifferentModifiersAsDistinctBindings() {
        let plan = GlobalHotKeyController.makePlan(
            followUp: binding(key: "f", command: true),
            ask: binding(key: "F", option: true),
            switchMode: binding(key: "f", control: true)
        )

        #expect(plan.bindings.count == 3)
        #expect(plan.errors.isEmpty)
    }

    @Test func updateUnregistersOldBindingsAndRegistersOnlyTheValidatedPlan() {
        let registrar = RecordingHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            onAction: { _ in },
            registrar: registrar,
            installsEventHandler: false
        )
        controller.update(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )
        let duplicate = binding(key: "f", command: true)
        let distinct = binding(key: "g", option: true)

        controller.update(
            followUp: duplicate,
            ask: binding(key: "F", command: true),
            switchMode: distinct
        )

        #expect(registrar.unregisteredActions == [.followUp, .ask, .switchMode])
        #expect(registrar.registeredActions == [
            .followUp, .ask, .switchMode, .switchMode,
        ])
        #expect(controller.errors == [
            .followUp: .duplicateBinding,
            .ask: .duplicateBinding,
        ])
    }

    @Test func updateReportsSystemRegistrationFailureWithoutClaimingSuccess() {
        let registrar = RecordingHotKeyRegistrar(failing: [.ask: -9876])
        let controller = GlobalHotKeyController(
            onAction: { _ in },
            registrar: registrar,
            installsEventHandler: false
        )

        controller.update(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )

        #expect(registrar.registeredActions == [.followUp, .ask, .switchMode])
        #expect(controller.errors == [.ask: .registrationFailed(-9876)])
        #expect(registrar.activeActions == [.followUp, .switchMode])
    }

    @Test func failedEventHandlerInstallationPreventsAllRegistrations() {
        let registrar = RecordingHotKeyRegistrar()
        let installer = RecordingHotKeyEventInstaller(failureStatus: -4321)
        do {
            let controller = GlobalHotKeyController(
                onAction: { _ in },
                registrar: registrar,
                eventInstaller: installer
            )

            controller.update(
                followUp: .defaultFollowUp,
                ask: .defaultAsk,
                switchMode: .defaultSwitchMode
            )

            #expect(installer.installationCount == 1)
            #expect(registrar.registeredActions.isEmpty)
            #expect(controller.errors == [
                .followUp: .registrationFailed(-4321),
                .ask: .registrationFailed(-4321),
                .switchMode: .registrationFailed(-4321),
            ])

            controller.invalidate()
            #expect(installer.removalCount == 0)
        }
        #expect(installer.removalCount == 0)
    }

    @Test func successfulInjectedEventHandlerAllowsRegistrations() {
        let registrar = RecordingHotKeyRegistrar()
        let installer = RecordingHotKeyEventInstaller()
        let controller = GlobalHotKeyController(
            onAction: { _ in },
            registrar: registrar,
            eventInstaller: installer
        )

        controller.update(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )

        #expect(installer.installationCount == 1)
        #expect(registrar.registeredActions == [.followUp, .ask, .switchMode])
        #expect(controller.errors.isEmpty)
    }

    @Test func errorBridgePublishesExistingAndSubsequentRegistrationErrorsToAssistant() {
        let registrar = RecordingHotKeyRegistrar()
        let controller = GlobalHotKeyController(
            onAction: { _ in },
            registrar: registrar,
            eventInstaller: RecordingHotKeyEventInstaller()
        )
        controller.update(
            followUp: binding(key: "f"),
            ask: binding(key: "f", command: true),
            switchMode: binding(key: "F", command: true)
        )
        let assistant = AssistantCoordinator()
        let bridge = AssistantHotKeyRegistrationErrorBridge(
            controller: controller,
            assistant: assistant
        )

        #expect(assistant.hotKeyRegistrationErrors == [
            .followUp: .invalidBinding,
            .ask: .duplicateBinding,
            .switchMode: .duplicateBinding,
        ])

        controller.update(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )
        #expect(assistant.hotKeyRegistrationErrors.isEmpty)

        registrar.setFailure(status: -8080, for: .ask)
        controller.update(
            followUp: .defaultFollowUp,
            ask: .defaultAsk,
            switchMode: .defaultSwitchMode
        )
        #expect(assistant.hotKeyRegistrationErrors == [.ask: .registrationFailed(-8080)])

        controller.invalidate()
        #expect(controller.errors.isEmpty)
        #expect(assistant.hotKeyRegistrationErrors.isEmpty)
        bridge.invalidate()
    }

    @Test func eventRoutingIgnoresForeignSignaturesAndUnknownActions() {
        #expect(GlobalHotKeyController.action(for: .init(
            signature: GlobalHotKeyController.eventSignature,
            id: GlobalHotKeyAction.followUp.rawValue
        )) == .followUp)
        #expect(GlobalHotKeyController.action(for: .init(
            signature: OSType(0x4F544852),
            id: GlobalHotKeyAction.ask.rawValue
        )) == nil)
        #expect(GlobalHotKeyController.action(for: .init(
            signature: GlobalHotKeyController.eventSignature,
            id: 999
        )) == nil)
    }

    private func binding(
        key: String,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) -> HotKeyBinding {
        HotKeyBinding(
            key: key,
            useCommand: command,
            useOption: option,
            useControl: control,
            useShift: shift
        )
    }
}

private final class RecordingHotKeyRegistrar: GlobalHotKeyRegistering {
    private var failing: [GlobalHotKeyAction: OSStatus]
    private(set) var registeredActions: [GlobalHotKeyAction] = []
    private(set) var unregisteredActions: [GlobalHotKeyAction] = []
    private(set) var activeActions: [GlobalHotKeyAction] = []

    init(failing: [GlobalHotKeyAction: OSStatus] = [:]) {
        self.failing = failing
    }

    func setFailure(status: OSStatus?, for action: GlobalHotKeyAction) {
        failing[action] = status
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: GlobalHotKeyAction
    ) -> Result<GlobalHotKeyRegistration, HotKeySystemRegistrationFailure> {
        registeredActions.append(action)
        if let status = failing[action] {
            return .failure(.init(status: status))
        }
        activeActions.append(action)
        return .success(GlobalHotKeyRegistration(action: action))
    }

    func unregister(_ registration: GlobalHotKeyRegistration) {
        unregisteredActions.append(registration.action)
        activeActions.removeAll { $0 == registration.action }
    }
}

private final class RecordingHotKeyEventInstaller: GlobalHotKeyEventInstalling {
    private let failureStatus: OSStatus?
    private(set) var installationCount = 0
    private(set) var removalCount = 0

    init(failureStatus: OSStatus? = nil) {
        self.failureStatus = failureStatus
    }

    func install(
        userData: UnsafeMutableRawPointer
    ) -> Result<GlobalHotKeyEventHandlerInstallation, HotKeySystemRegistrationFailure> {
        installationCount += 1
        if let failureStatus {
            return .failure(.init(status: failureStatus))
        }
        return .success(GlobalHotKeyEventHandlerInstallation())
    }

    func remove(_ installation: GlobalHotKeyEventHandlerInstallation) {
        removalCount += 1
    }
}
