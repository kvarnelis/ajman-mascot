import AppKit

final class Animator {
    static let sleepPoseHoldRange: ClosedRange<TimeInterval> = 20...45

    private enum CalmPoseMode {
        case loaf
        case sleep
        case wake
    }

    private var sheet: SpriteSheet
    private weak var view: PetView?
    private let sleepHoldRange: ClosedRange<TimeInterval>
    private var temperament: Temperament
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var frameDurations: [TimeInterval] = []
    private var calmPoseWeights: [Double] = []
    private var calmPoseMode: CalmPoseMode?
    private var currentCalmPoseIndex: Int?
    private var frameIndex = 0

    private(set) var currentState: AnimationState = .idle
    var isPlayingLoaf: Bool { calmPoseMode == .loaf }
    var isPlayingSleep: Bool { calmPoseMode == .sleep }
    var isPlayingWake: Bool { calmPoseMode == .wake }
    var isPlayingCalmPose: Bool { calmPoseMode != nil }
    var currentLoafPoseIndex: Int? { isPlayingLoaf ? currentCalmPoseIndex : nil }
    var currentSleepPoseIndex: Int? { isPlayingSleep ? currentCalmPoseIndex : nil }
    var currentWakePoseIndex: Int? { isPlayingWake ? currentCalmPoseIndex : nil }
    var stateDidChange: ((AnimationState) -> Void)?
    var availableStates: [AnimationState] { sheet.animationTable.states }

    init(
        sheet: SpriteSheet,
        view: PetView?,
        sleepHoldRange: ClosedRange<TimeInterval> = Animator.sleepPoseHoldRange,
        temperament: Temperament = .normal
    ) {
        self.sheet = sheet
        self.view = view
        self.sleepHoldRange = sleepHoldRange
        self.temperament = temperament
    }

    func setTemperament(_ temperament: Temperament) {
        guard self.temperament != temperament else { return }
        self.temperament = temperament
        if isPlayingLoaf || isPlayingSleep {
            timer?.cancel()
            timer = nil
            view?.setBreathingEnabled(false)
            view?.setBreathingEnabled(true, temperament: temperament)
            showCalmPoseAndScheduleNext(crossfadeDuration: 0)
            return
        }
        // Restart only the passive idle loop so the new visible-energy setting
        // takes effect now without disturbing agent, debug, or calm-pose states.
        if currentState == .idle, !isPlayingCalmPose {
            play(.idle, force: true)
        }
    }

    func replaceSheet(_ sheet: SpriteSheet, playing state: AnimationState) {
        timer?.cancel()
        timer = nil
        frames = []
        frameDurations = []
        calmPoseWeights = []
        frameIndex = 0
        self.sheet = sheet
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        currentState = state
        play(sheet.animationTable.definition(for: state) == nil ? .idle : state, force: true)
    }

    func play(_ state: AnimationState) {
        play(state, force: false)
    }

    private func play(_ state: AnimationState, force: Bool) {
        guard force || isPlayingCalmPose || state != currentState || timer == nil else { return }
        guard let definition = sheet.animationTable.definition(for: state) else { return }
        timer?.cancel()
        timer = nil
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        currentState = state
        frames = sheet.frames(for: definition)
        frameDurations = playbackDurations(for: definition)
        frameIndex = 0
        stateDidChange?(state)
        showCurrentFrameAndScheduleNext()
    }

    func playLoaf(_ animation: SleepAnimation) {
        playRotatingPoses(animation, mode: .loaf, initialCrossfade: 0.8)
    }

    func playSleep(_ animation: SleepAnimation) {
        playRotatingPoses(animation, mode: .sleep, initialCrossfade: isPlayingLoaf ? 1.2 : 0)
    }

    func playWake(_ animation: SleepAnimation) {
        guard !animation.frames.isEmpty else { return }
        timer?.cancel()
        timer = nil
        calmPoseMode = .wake
        frames = animation.frames
        frameDurations = []
        calmPoseWeights = animation.poseWeights
        currentCalmPoseIndex = chooseCalmPose(excluding: nil)
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        if let poseIndex = currentCalmPoseIndex, frames.indices.contains(poseIndex) {
            view?.setImage(frames[poseIndex], crossfadeDuration: 0.45)
        }
    }

    @discardableResult
    func playSingleFrame(_ state: AnimationState, frameIndex: Int) -> Bool {
        guard let definition = sheet.animationTable.definition(for: state) else { return false }
        let stateFrames = sheet.frames(for: definition)
        guard stateFrames.indices.contains(frameIndex) else { return false }

        timer?.cancel()
        timer = nil
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        currentState = state
        frames = [stateFrames[frameIndex]]
        frameDurations = []
        self.frameIndex = 0
        stateDidChange?(state)
        view?.image = frames[0]
        return true
    }

    @discardableResult
    func playHeldPose(_ animation: SleepAnimation, frameIndex: Int) -> Bool {
        guard animation.frames.indices.contains(frameIndex) else { return false }
        timer?.cancel()
        timer = nil
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        frames = [animation.frames[frameIndex]]
        frameDurations = []
        self.frameIndex = 0
        view?.image = frames[0]
        return true
    }

    func playLoop(_ animation: SleepAnimation, as state: AnimationState, frameDuration: TimeInterval) {
        guard !animation.frames.isEmpty, frameDuration > 0 else { return }
        timer?.cancel()
        timer = nil
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        currentState = state
        frames = animation.frames
        frameDurations = Array(repeating: frameDuration, count: frames.count)
        frameIndex = 0
        stateDidChange?(state)
        showCurrentFrameAndScheduleNext()
    }

    func setScratchRaking(_ enabled: Bool, amplitude: CGFloat = ScratchBehavior.rakeAmplitude) {
        view?.setScratchRaking(enabled, amplitude: amplitude)
    }

    func duration(of state: AnimationState) -> TimeInterval? {
        sheet.animationTable.definition(for: state).map { playbackDurations(for: $0).reduce(0, +) }
    }

    func playbackDurations(of state: AnimationState) -> [TimeInterval]? {
        sheet.animationTable.definition(for: state).map(playbackDurations(for:))
    }

    func stop() {
        timer?.cancel()
        timer = nil
        frames = []
        frameDurations = []
        calmPoseMode = nil
        currentCalmPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.setScratchRaking(false)
        view?.image = nil
    }

    private func playRotatingPoses(
        _ animation: SleepAnimation,
        mode: CalmPoseMode,
        initialCrossfade: TimeInterval
    ) {
        guard !animation.frames.isEmpty, calmPoseMode != mode || timer == nil else { return }
        timer?.cancel()
        timer = nil
        calmPoseMode = mode
        frames = animation.frames
        frameDurations = []
        calmPoseWeights = animation.poseWeights
        currentCalmPoseIndex = chooseCalmPose(excluding: nil)
        view?.setBreathingEnabled(true, temperament: temperament)
        view?.setScratchRaking(false)
        showCalmPoseAndScheduleNext(crossfadeDuration: initialCrossfade)
    }

    private func showCalmPoseAndScheduleNext(crossfadeDuration: TimeInterval) {
        guard calmPoseMode == .loaf || calmPoseMode == .sleep,
              let poseIndex = currentCalmPoseIndex,
              frames.indices.contains(poseIndex) else { return }
        view?.setImage(frames[poseIndex], crossfadeDuration: crossfadeDuration)

        let delay = TimeInterval.random(in: temperament.scaledCalmPose(range: sleepHoldRange))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.calmPoseMode == .loaf || self.calmPoseMode == .sleep else { return }
            self.timer?.cancel()
            self.timer = nil
            self.currentCalmPoseIndex = self.chooseCalmPose(excluding: poseIndex)
            self.showCalmPoseAndScheduleNext(crossfadeDuration: 1.2)
        }
        self.timer = timer
        timer.resume()
    }

    private func chooseCalmPose(excluding excludedIndex: Int?) -> Int? {
        let candidates = frames.indices.filter { $0 != excludedIndex }
        guard !candidates.isEmpty else { return frames.indices.first }
        let total = candidates.reduce(0.0) { partial, index in
            partial + max(calmPoseWeights.indices.contains(index) ? calmPoseWeights[index] : 1, 0)
        }
        guard total > 0 else { return candidates.randomElement() }
        var draw = Double.random(in: 0..<total)
        for index in candidates {
            draw -= max(calmPoseWeights.indices.contains(index) ? calmPoseWeights[index] : 1, 0)
            if draw < 0 { return index }
        }
        return candidates.last
    }

    private func showCurrentFrameAndScheduleNext() {
        guard !frames.isEmpty, frameDurations.count == frames.count else { return }
        view?.image = frames[frameIndex]
        let delay = frameDurations[frameIndex]
        let nextIndex = (frameIndex + 1) % frames.count

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.frameIndex = nextIndex
            self.showCurrentFrameAndScheduleNext()
        }
        self.timer = timer
        timer.resume()
    }

    private func playbackDurations(for definition: AnimationDefinition) -> [TimeInterval] {
        guard definition.state == .idle else { return definition.durations }
        return definition.durations.map(temperament.scaledIdleFrameDuration)
    }

    deinit {
        timer?.cancel()
    }
}
