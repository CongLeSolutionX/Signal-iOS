//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalRingRTC
import SignalServiceKit
import SignalUI

@objc
protocol CallControlsDelegate: AnyObject {
    func didPressRing()
    func didPressJoin()
    func didPressHangup()
    func didPressMore()
}

class CallControls: UIView {
    private lazy var topStackView = createTopStackView()
    private lazy var hangUpButton: CallButton = {
        let button = createButton(
            iconName: "phone-down-fill-28",
            accessibilityLabel: viewModel.hangUpButtonAccessibilityLabel,
            action: #selector(CallControlsViewModel.didPressHangup)
        )
        button.unselectedBackgroundColor = useCallDrawerStyling ? UIColor(rgbHex: 0xEB5545) : .ows_accentRed
        return button
    }()
    private(set) lazy var audioSourceButton = createButton(
        iconName: "speaker-fill-28",
        accessibilityLabel: viewModel.audioSourceAccessibilityLabel,
        action: #selector(CallControlsViewModel.didPressAudioSource)
    )
    private lazy var muteButton = createButton(
        iconName: "mic-fill",
        selectedIconName: "mic-slash-fill-28",
        accessibilityLabel: viewModel.muteButtonAccessibilityLabel,
        action: #selector(CallControlsViewModel.didPressMute)
    )
    private lazy var videoButton = createButton(
        iconName: "video-fill-28",
        selectedIconName: "video-slash-fill-28",
        accessibilityLabel: viewModel.videoButtonAccessibilityLabel,
        action: #selector(CallControlsViewModel.didPressVideo)
    )
    private lazy var ringButton = createButton(
        iconName: "bell-ring-fill-28",
        selectedIconName: "bell-slash-fill",
        // TODO: Accessibility label
        action: #selector(CallControlsViewModel.didPressRing)
    )
    private lazy var flipCameraButton: CallButton = {
        let button = createButton(
            iconName: "switch-camera-28",
            accessibilityLabel: viewModel.flipCameraButtonAccessibilityLabel,
            action: #selector(CallControlsViewModel.didPressFlipCamera)
        )
        button.selectedIconColor = button.iconColor
        button.selectedBackgroundColor = button.unselectedBackgroundColor
        return button
    }()
    private lazy var moreButton = createButton(
        iconName: "more",
        accessibilityLabel: viewModel.moreButtonAccessibilityLabel,
        action: #selector(CallControlsViewModel.didPressMore)
    )

    private lazy var joinButtonActivityIndicator = UIActivityIndicatorView(style: .medium)

    private lazy var joinButton: UIButton = {
        let height: CGFloat = HeightConstants.joinButtonHeight

        let button = OWSButton()
        button.setTitleColor(.ows_white, for: .normal)
        button.setBackgroundImage(UIImage.image(color: .ows_accentGreen), for: .normal)
        button.titleLabel?.font = UIFont.dynamicTypeBodyClamped.semibold()
        button.clipsToBounds = true
        button.layer.cornerRadius = height / 2
        button.block = { [weak self, unowned button] in
            self?.viewModel.didPressJoin()
        }
        button.ows_contentEdgeInsets = UIEdgeInsets(top: 17, leading: 17, bottom: 17, trailing: 17)
        button.addSubview(joinButtonActivityIndicator)
        joinButtonActivityIndicator.autoCenterInSuperview()

        // Expand the button to fit text if necessary.
        button.autoSetDimension(.width, toSize: 168, relation: .greaterThanOrEqual)
        button.autoSetDimension(.height, toSize: height)
        return button
    }()

    static func joinButtonLabel(for call: SignalCall) -> String {
        return CallControlsViewModel.joinButtonLabel(for: call)
    }

    private lazy var gradientView: UIView = {
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.ows_blackAlpha60.cgColor
        ]
        let view = OWSLayerView(frame: .zero) { view in
            gradientLayer.frame = view.bounds
        }
        view.layer.addSublayer(gradientLayer)
        return view
    }()

    private weak var delegate: CallControlsDelegate!
    private let viewModel: CallControlsViewModel

    private let useCallDrawerStyling: Bool

    init(
        call: SignalCall,
        callService: CallService,
        confirmationToastManager: CallControlsConfirmationToastManager,
        useCallDrawerStyling: Bool,
        delegate: CallControlsDelegate
    ) {
        let viewModel = CallControlsViewModel(
            call: call,
            callService: callService,
            confirmationToastManager: confirmationToastManager,
            useCallDrawerStyling: useCallDrawerStyling,
            delegate: delegate
        )
        self.viewModel = viewModel
        self.useCallDrawerStyling = useCallDrawerStyling
        self.delegate = delegate
        super.init(frame: .zero)

        viewModel.refreshView = { [weak self] in
            self?.updateControls()
        }

        addSubview(gradientView)
        gradientView.autoPinEdgesToSuperviewEdges()

        let joinButtonContainer = UIView()
        joinButtonContainer.addSubview(joinButton)
        joinButtonContainer.layoutMargins = UIEdgeInsets(hMargin: 16, vMargin: 0)
        joinButton.autoPinWidthToSuperviewMargins(relation: .lessThanOrEqual)
        joinButton.autoPinHeightToSuperview()

        let controlsStack = UIStackView(arrangedSubviews: [
            topStackView,
            joinButtonContainer
        ])
        controlsStack.axis = .vertical
        controlsStack.spacing = useCallDrawerStyling ? HeightConstants.stackSpacingInDrawer : HeightConstants.stackSpacingWithoutDrawer
        controlsStack.alignment = .center

        addSubview(controlsStack)
        controlsStack.autoPinWidthToSuperview()
        controlsStack.autoPinEdge(
            toSuperviewSafeArea: .bottom,
            withInset: HeightConstants.bottomPadding,
            relation: .lessThanOrEqual
        )
        let insetFromBottom: CGFloat = useCallDrawerStyling ? 56 : 32
        let insetFromTop: CGFloat = useCallDrawerStyling ? 0 : 16
        NSLayoutConstraint.autoSetPriority(.defaultHigh - 1) {
            controlsStack.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: insetFromBottom)
        }
        controlsStack.autoPinEdge(toSuperviewEdge: .top, withInset: insetFromTop)

        updateControls()
    }

    func createTopStackView() -> UIStackView {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 16

        stackView.addArrangedSubview(audioSourceButton)
        stackView.addArrangedSubview(flipCameraButton)
        stackView.addArrangedSubview(videoButton)
        stackView.addArrangedSubview(muteButton)
        stackView.addArrangedSubview(moreButton)
        stackView.addArrangedSubview(ringButton)
        stackView.addArrangedSubview(hangUpButton)

        return stackView
    }

    private var heightAfterLastUpdate: CGFloat = 0

    private func updateControls() {
        // Top row
        audioSourceButton.isHidden = viewModel.audioSourceButtonIsHidden
        hangUpButton.isHidden = viewModel.hangUpButtonIsHidden
        muteButton.isHidden = viewModel.muteButtonIsHidden
        moreButton.isHidden = viewModel.moreButtonIsHidden
        videoButton.isHidden = viewModel.videoButtonIsHidden
        flipCameraButton.isHidden = viewModel.flipCameraButtonIsHidden
        ringButton.isHidden = viewModel.ringButtonIsHidden

        // Bottom row
        joinButton.superview?.isHidden = viewModel.joinButtonIsHidden

        // Sizing and spacing
        let controlCount = topStackView.arrangedSubviews.filter({!$0.isHidden}).count
        topStackView.spacing = viewModel.controlSpacing(controlCount: controlCount)
        let shouldControlButtonsBeSmall = viewModel.shouldControlButtonsBeSmall(controlCount: controlCount)
        for view in topStackView.arrangedSubviews {
            if let button = view as? CallButton {
                button.isSmall = shouldControlButtonsBeSmall
            }
        }

        // Show/hide the superview to adjust the containing stack.
        gradientView.isHidden = viewModel.gradientViewIsHidden

        videoButton.isSelected = viewModel.videoButtonIsSelected
        muteButton.isSelected = viewModel.muteButtonIsSelected
        audioSourceButton.isSelected = viewModel.audioSourceButtonIsSelected
        ringButton.isSelected = viewModel.ringButtonIsSelected
        flipCameraButton.isSelected = viewModel.flipCameraButtonIsSelected
        moreButton.isSelected = viewModel.moreButtonIsSelected

        if !viewModel.audioSourceButtonIsHidden {
            let config = viewModel.audioSourceButtonConfiguration
            audioSourceButton.showDropdownArrow = config.showDropdownArrow
            audioSourceButton.iconName = config.iconName
        }

        if
            !viewModel.ringButtonIsHidden,
            let ringButtonConfig = viewModel.ringButtonConfiguration
        {
            ringButton.isUserInteractionEnabled = ringButtonConfig.isUserInteractionEnabled
            ringButton.isSelected = ringButtonConfig.isSelected
            ringButton.shouldDrawAsDisabled = ringButtonConfig.shouldDrawAsDisabled
        }

        if !viewModel.joinButtonIsHidden {
            let joinButtonConfig = viewModel.joinButtonConfig
            joinButton.setTitle(joinButtonConfig.label, for: .normal)
            joinButton.setTitleColor(joinButtonConfig.color, for: .normal)
            joinButton.ows_adjustsImageWhenHighlighted = joinButtonConfig.adjustsImageWhenHighlighted
            joinButton.isUserInteractionEnabled = joinButtonConfig.isUserInteractionEnabled
            if viewModel.shouldJoinButtonActivityIndicatorBeAnimating {
                joinButtonActivityIndicator.startAnimating()
            } else {
                joinButtonActivityIndicator.stopAnimating()
            }
        }

        hangUpButton.accessibilityLabel = viewModel.hangUpButtonAccessibilityLabel
        audioSourceButton.accessibilityLabel = viewModel.audioSourceAccessibilityLabel
        muteButton.accessibilityLabel = viewModel.muteButtonAccessibilityLabel
        videoButton.accessibilityLabel = viewModel.videoButtonAccessibilityLabel
        flipCameraButton.accessibilityLabel = viewModel.flipCameraButtonAccessibilityLabel
        moreButton.accessibilityLabel = viewModel.moreButtonAccessibilityLabel

        if self.heightAfterLastUpdate != self.currentHeight {
            callControlsHeightObservers.elements.forEach {
                $0.callControlsHeightDidChange(newHeight: currentHeight)
            }
        }

        self.heightAfterLastUpdate = self.currentHeight
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createButton(
        iconName: String,
        selectedIconName: String? = nil,
        accessibilityLabel: String? = nil,
        action: Selector
    ) -> CallButton {
        let button = CallButton(iconName: iconName)
        button.selectedIconName = selectedIconName
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(viewModel, action: action, for: .touchUpInside)
        button.setContentHuggingHorizontalHigh()
        button.setCompressionResistanceHorizontalLow()
        if useCallDrawerStyling {
            button.unselectedBackgroundColor = CallButton.unselectedBackgroundColorInDrawer
            button.selectedIconColor = CallButton.selectedIconColorInDrawer
        } else {
            button.alpha = 0.9
        }
        return button
    }

    // MARK: Height Observing

    private var callControlsHeightObservers: WeakArray<any CallControlsHeightObserver> = []

    func addHeightObserver(_ observer: CallControlsHeightObserver) {
        callControlsHeightObservers.append(observer)
    }

    var currentHeight: CGFloat {
        var height = self.buttonRowHeight + HeightConstants.bottomPadding
        if !viewModel.joinButtonIsHidden {
            height += HeightConstants.joinButtonHeight
            height += (self.useCallDrawerStyling ? HeightConstants.stackSpacingInDrawer : HeightConstants.stackSpacingWithoutDrawer)
        }
        return height
    }

    private var buttonRowHeight: CGFloat {
        self.muteButton.currentIconSize
    }

    private enum HeightConstants {
        static let joinButtonHeight: CGFloat = 56
        static let stackSpacingInDrawer: CGFloat = 30
        static let stackSpacingWithoutDrawer: CGFloat = 40
        static let bottomPadding: CGFloat = 40
    }
}

protocol CallControlsHeightObserver {
    func callControlsHeightDidChange(newHeight: CGFloat)
}

// MARK: - View Model

private class CallControlsViewModel {
    private let call: SignalCall
    private let callService: CallService
    private let useCallDrawerStyling: Bool
    private weak var delegate: CallControlsDelegate?
    private let confirmationToastManager: CallControlsConfirmationToastManager
    fileprivate var refreshView: (() -> Void)?
    init(
        call: SignalCall,
        callService: CallService,
        confirmationToastManager: CallControlsConfirmationToastManager,
        useCallDrawerStyling: Bool,
        delegate: CallControlsDelegate
    ) {
        self.call = call
        self.callService = callService
        self.confirmationToastManager = confirmationToastManager
        self.useCallDrawerStyling = useCallDrawerStyling
        self.delegate = delegate
        switch call.mode {
        case .individual(let call):
            call.addObserverAndSyncState(self)
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            call.addObserver(self, syncStateImmediately: true)
        }
        callService.audioService.delegate = self
    }

    deinit {
        callService.audioService.delegate = nil
    }

    private var didOverrideDefaultMuteState = false

    private var hasExternalAudioInputsAndAudioSource: Bool {
        let audioService = callService.audioService
        return audioService.hasExternalInputs && audioService.currentAudioSource != nil
    }

    var audioSourceButtonIsHidden: Bool {
        if hasExternalAudioInputsAndAudioSource {
            return false
        } else if UIDevice.current.isIPad {
            // iPad *only* supports speaker mode, if there are no external
            // devices connected, so we don't need to show the button unless
            // we have alternate audio sources.
            return true
        } else {
            return !call.isOutgoingVideoMuted
        }
    }

    struct AudioSourceButtonConfiguration {
        let showDropdownArrow: Bool
        let iconName: String
    }

    var audioSourceButtonConfiguration: AudioSourceButtonConfiguration {
        let showDropdownArrow: Bool
        let iconName: String
        if
            callService.audioService.hasExternalInputs,
            let audioSource = callService.audioService.currentAudioSource
        {
            showDropdownArrow = true
            if audioSource.isBuiltInEarPiece {
                iconName = "phone-fill-28"
            } else if audioSource.isBuiltInSpeaker {
                iconName = "speaker-fill-28"
            } else {
                iconName = "speaker-bt-fill-28"
            }
        } else {
            // No bluetooth audio detected
            showDropdownArrow = false
            iconName = "speaker-fill-28"
        }
        return AudioSourceButtonConfiguration(showDropdownArrow: showDropdownArrow, iconName: iconName)
    }

    var hangUpButtonIsHidden: Bool {
        switch call.mode {
        case .individual(_):
            return false
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            return !call.hasJoinedOrIsWaitingForAdminApproval
        }
    }

    var muteButtonIsHidden: Bool {
        return false
    }

    var videoButtonIsHidden: Bool {
        return false
    }

    var flipCameraButtonIsHidden: Bool {
        if call.isOutgoingVideoMuted {
            return true
        }

        switch call.mode {
        case .individual(let call):
            return ![.idle, .dialing, .remoteRinging, .localRinging_Anticipatory, .localRinging_ReadyToAnswer].contains(call.state)
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            if FeatureFlags.groupCallDrawerSupport && call.isJustMe {
                return true
            }
            return call.hasJoinedOrIsWaitingForAdminApproval
        }
    }

    var joinButtonIsHidden: Bool {
        switch call.mode {
        case .individual(_):
            // TODO: Introduce lobby for starting 1:1 video calls.
            return true
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            return call.hasJoinedOrIsWaitingForAdminApproval
        }
    }

    struct JoinButtonConfiguration {
        let label: String
        let color: UIColor
        let adjustsImageWhenHighlighted: Bool
        let isUserInteractionEnabled: Bool
    }

    var joinButtonConfig: JoinButtonConfiguration {
        if call.isFull {
            // Make the button look disabled, but don't actually disable it.
            // We want to show a toast if the user taps anyway.
            return JoinButtonConfiguration(
                label: OWSLocalizedString(
                    "GROUP_CALL_IS_FULL",
                    comment: "Text explaining the group call is full"
                ),
                color: .ows_whiteAlpha40,
                adjustsImageWhenHighlighted: false,
                isUserInteractionEnabled: true
            )
        }
        if call.joinState == .joining {
            return JoinButtonConfiguration(
                label: "",
                color: .ows_whiteAlpha40,
                adjustsImageWhenHighlighted: false,
                isUserInteractionEnabled: false
            )
        }
        return JoinButtonConfiguration(
            label: Self.joinButtonLabel(for: call),
            color: .white,
            adjustsImageWhenHighlighted: true,
            isUserInteractionEnabled: true
        )
    }

    static func joinButtonLabel(for call: SignalCall) -> String {
        switch call.mode {
        case .individual:
            // We only show a lobby for 1:1 calls when the call is being initiated.
            // TODO: The work of adding the lobby for 1:1 calls in the unified call view
            // controller (currently GroupCallViewController) is not yet complete.
            return startCallText()
        case .groupThread(let call):
            return call.ringRestrictions.contains(.callInProgress) ? CallStrings.joinGroupCall : startCallText()
        case .callLink(let call):
            return call.mayNeedToAskToJoin ? askToJoinText() : CallStrings.joinGroupCall
        }
    }

    private static func startCallText() -> String {
        return OWSLocalizedString(
            "CALL_START_BUTTON",
            comment: "Button to start a call"
        )
    }

    private static func askToJoinText() -> String {
        return OWSLocalizedString(
            "ASK_TO_JOIN_CALL",
            comment: "Button to try to join a call. The admin may need to approve the request before the user can join."
        )
    }

    var shouldJoinButtonActivityIndicatorBeAnimating: Bool {
        return (call.joinState == .joining || call.joinState == .pending) && !joinButtonIsHidden
    }

    var ringButtonIsHidden: Bool {
        switch call.mode {
        case .individual(_):
            return true
        case .groupThread(let call):
            return call.joinState == .joined || call.ringRestrictions.contains(.callInProgress)
        case .callLink:
            return true
        }
    }

    struct RingButtonConfiguration {
        let isUserInteractionEnabled: Bool
        let isSelected: Bool
        let shouldDrawAsDisabled: Bool
    }

    var ringButtonConfiguration: RingButtonConfiguration? {
        switch call.mode {
        case .individual(_):
            // We never show the ring button for 1:1 calls.
            return nil
        case .groupThread(let call):
            // Leave the button visible but locked if joining, like the "join call" button.
            let isUserInteractionEnabled = call.joinState == .notJoined
            let isSelected: Bool
            if
                call.ringRestrictions.isEmpty,
                case .shouldRing = call.groupCallRingState
            {
                isSelected = false
            } else {
                isSelected = true
            }
            // Leave the button enabled so we can present an explanatory toast, but show it disabled.
            let shouldDrawAsDisabled = !call.ringRestrictions.isEmpty
            return RingButtonConfiguration(
                isUserInteractionEnabled: isUserInteractionEnabled,
                isSelected: isSelected,
                shouldDrawAsDisabled: shouldDrawAsDisabled
            )
        case .callLink:
            return nil
        }
    }

    var moreButtonIsHidden: Bool {
        switch call.mode {
        case .individual(_):
            return true
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            // [Call Link] TODO: Figure out if this should be shown while pending.
            return call.ringRtcCall.localDeviceState.joinState != .joined
        }
    }

    var gradientViewIsHidden: Bool {
        switch call.mode {
        case .individual:
            if useCallDrawerStyling {
                return true
            } else {
                return call.joinState != .joined
            }
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            if useCallDrawerStyling {
                return true
            } else {
                return !call.hasJoinedOrIsWaitingForAdminApproval
            }
        }
    }

    var videoButtonIsSelected: Bool {
        return call.isOutgoingVideoMuted
    }

    var muteButtonIsSelected: Bool {
        return call.isOutgoingAudioMuted
    }

    var ringButtonIsSelected: Bool {
        if let config = ringButtonConfiguration {
            return config.isSelected
        }
        // Ring button shouldn't be shown in this case anyway.
        return false
    }

    var audioSourceButtonIsSelected: Bool {
        return callService.audioService.isSpeakerEnabled
    }

    var flipCameraButtonIsSelected: Bool {
        return false
    }

    var moreButtonIsSelected: Bool {
        return false
    }

    func controlSpacing(controlCount: Int) -> CGFloat {
        return (UIDevice.current.isNarrowerThanIPhone6 && controlCount > 4) ? 12 : 16
    }

    func shouldControlButtonsBeSmall(controlCount: Int) -> Bool {
        return UIDevice.current.isIPad ? false : controlCount > 4
    }
}

extension CallControlsViewModel: GroupCallObserver {
    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        refreshView?()
    }

    func groupCallPeekChanged(_ call: GroupCall) {
        // Mute if there's more than 8 people in the call.
        if call.shouldMuteAutomatically(), !didOverrideDefaultMuteState, !muteButtonIsSelected {
            callService.updateIsLocalAudioMuted(isLocalAudioMuted: true)
        }
        refreshView?()
    }

    func groupCallRemoteDeviceStatesChanged(_ call: GroupCall) {
        refreshView?()
    }

    func groupCallEnded(_ call: GroupCall, reason: GroupCallEndReason) {
        refreshView?()
    }
}

extension CallControlsViewModel: IndividualCallObserver {
    func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        refreshView?()
    }

    func individualCallLocalVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        refreshView?()
    }

    func individualCallLocalAudioMuteDidChange(_ call: IndividualCall, isAudioMuted: Bool) {
        refreshView?()
    }

    func individualCallHoldDidChange(_ call: IndividualCall, isOnHold: Bool) {
        refreshView?()
    }

    func individualCallRemoteVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        refreshView?()
    }

    func individualCallRemoteSharingScreenDidChange(_ call: IndividualCall, isRemoteSharingScreen: Bool) {
        refreshView?()
    }
}

extension CallControlsViewModel: CallAudioServiceDelegate {
    func callAudioServiceDidChangeAudioSession(_ callAudioService: CallAudioService) {
        refreshView?()
    }

    func callAudioServiceDidChangeAudioSource(_ callAudioService: CallAudioService, audioSource: AudioSource?) {
        refreshView?()
    }
}

extension CallControlsViewModel {
    @objc
    func didPressHangup() {
        callService.callUIAdapter.localHangupCall(call)
        delegate?.didPressHangup()
    }

    @objc
    func didPressAudioSource() {
        if callService.audioService.hasExternalInputs {
            callService.audioService.presentRoutePicker()
        } else {
            let shouldEnableSpeakerphone = !audioSourceButtonIsSelected
            callService.audioService.requestSpeakerphone(call: self.call, isEnabled: shouldEnableSpeakerphone)
            confirmationToastManager.toastInducingCallControlChangeDidOccur(state: .speakerphone(isOn: shouldEnableSpeakerphone))
        }
        refreshView?()
    }

    @objc
    func didPressMute() {
        let shouldMute = !muteButtonIsSelected
        callService.updateIsLocalAudioMuted(isLocalAudioMuted: shouldMute)
        confirmationToastManager.toastInducingCallControlChangeDidOccur(state: .mute(isOn: shouldMute))
        didOverrideDefaultMuteState = true
        refreshView?()
    }

    @objc
    func didPressVideo() {
        callService.updateIsLocalVideoMuted(isLocalVideoMuted: !call.isOutgoingVideoMuted)

        // When turning off video, default speakerphone to on.
        if call.isOutgoingVideoMuted && !callService.audioService.hasExternalInputs {
            callService.audioService.requestSpeakerphone(call: self.call, isEnabled: true)
        }
        refreshView?()
    }

    @objc
    func didPressRing() {
        switch call.mode {
        case .individual:
            owsFailDebug("Can't control ringing for an individual call.")
        case .groupThread(let call):
            if call.ringRestrictions.isEmpty {
                switch call.groupCallRingState {
                case .shouldRing:
                    call.groupCallRingState = .doNotRing
                    confirmationToastManager.toastInducingCallControlChangeDidOccur(state: .ring(isOn: false))
                case .doNotRing:
                    call.groupCallRingState = .shouldRing
                    confirmationToastManager.toastInducingCallControlChangeDidOccur(state: .ring(isOn: true))
                default:
                    owsFailBeta("Ring button should not have been available to press!")
                }
                refreshView?()
            }
            delegate?.didPressRing()
        case .callLink:
            owsFailDebug("Can't ring Call Link call.")
        }
    }

    @objc
    func didPressFlipCamera() {
        if let isUsingFrontCamera = call.videoCaptureController.isUsingFrontCamera {
            callService.updateCameraSource(call: call, isUsingFrontCamera: !isUsingFrontCamera)
            refreshView?()
        }
    }

    @objc
    func didPressJoin() {
        delegate?.didPressJoin()
    }

    @objc
    func didPressMore() {
        delegate?.didPressMore()
    }
}

// MARK: - Accessibility

extension CallControlsViewModel {
    public var hangUpButtonAccessibilityLabel: String {
        switch call.mode {
        case .individual(_):
            return OWSLocalizedString(
                "CALL_VIEW_HANGUP_LABEL",
                comment: "Accessibility label for hang up call"
            )
        case .groupThread, .callLink:
            return OWSLocalizedString(
                "CALL_VIEW_LEAVE_CALL_LABEL",
                comment: "Accessibility label for leaving a call"
            )
        }
    }

    public var audioSourceAccessibilityLabel: String {
        // TODO: This is not the most helpful descriptor.
        return OWSLocalizedString(
            "CALL_VIEW_AUDIO_SOURCE_LABEL",
            comment: "Accessibility label for selection the audio source"
        )
    }

    public var muteButtonAccessibilityLabel: String {
        if call.isOutgoingAudioMuted {
            return OWSLocalizedString(
                "CALL_VIEW_UNMUTE_LABEL",
                comment: "Accessibility label for unmuting the microphone"
            )
        } else {
            return OWSLocalizedString(
                "CALL_VIEW_MUTE_LABEL",
                comment: "Accessibility label for muting the microphone"
            )
        }
    }

    public var videoButtonAccessibilityLabel: String {
        if call.isOutgoingVideoMuted {
            return OWSLocalizedString(
                "CALL_VIEW_TURN_VIDEO_ON_LABEL",
                comment: "Accessibility label for turning on the camera"
            )
        } else {
            return OWSLocalizedString(
                "CALL_VIEW_TURN_VIDEO_OFF_LABEL",
                comment: "Accessibility label for turning off the camera"
            )
        }
    }

    public var flipCameraButtonAccessibilityLabel: String {
        return OWSLocalizedString(
            "CALL_VIEW_SWITCH_CAMERA_DIRECTION",
            comment: "Accessibility label to toggle front- vs. rear-facing camera"
        )
    }

    public var moreButtonAccessibilityLabel: String {
        return OWSLocalizedString(
            "CALL_VIEW_MORE_LABEL",
            comment: "Accessibility label for the More button in the Call Controls row."
        )
    }
}
