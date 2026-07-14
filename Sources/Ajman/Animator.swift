import AppKit

final class Animator {
    static let sleepPoseHoldRange: ClosedRange<TimeInterval> = 20...45

    private var sheet: SpriteSheet
    private weak var view: PetView?
    private let sleepHoldRange: ClosedRange<TimeInterval>
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var frameDurations: [TimeInterval] = []
    private var sleepPoseWeights: [Double] = []
    private var frameIndex = 0

    private(set) var currentState: AnimationState = .idle
    private(set) var isPlayingSleep = false
    private(set) var currentSleepPoseIndex: Int?
    var stateDidChange: ((AnimationState) -> Void)?
    var availableStates: [AnimationState] { sheet.animationTable.states }

    init(
        sheet: SpriteSheet,
        view: PetView?,
        sleepHoldRange: ClosedRange<TimeInterval> = Animator.sleepPoseHoldRange
    ) {
        self.sheet = sheet
        self.view = view
        self.sleepHoldRange = sleepHoldRange
    }

    func replaceSheet(_ sheet: SpriteSheet, playing state: AnimationState) {
        timer?.cancel()
        timer = nil
        frames = []
        frameDurations = []
        sleepPoseWeights = []
        frameIndex = 0
        self.sheet = sheet
        isPlayingSleep = false
        currentSleepPoseIndex = nil
        view?.setBreathingEnabled(false)
        currentState = state
        play(sheet.animationTable.definition(for: state) == nil ? .idle : state, force: true)
    }

    func play(_ state: AnimationState) {
        play(state, force: false)
    }

    private func play(_ state: AnimationState, force: Bool) {
        guard force || isPlayingSleep || state != currentState || timer == nil else { return }
        guard let definition = sheet.animationTable.definition(for: state) else { return }
        timer?.cancel()
        timer = nil
        isPlayingSleep = false
        currentSleepPoseIndex = nil
        view?.setBreathingEnabled(false)
        currentState = state
        frames = sheet.frames(for: definition)
        frameDurations = definition.durations
        frameIndex = 0
        stateDidChange?(state)
        showCurrentFrameAndScheduleNext()
    }

    func playSleep(_ animation: SleepAnimation) {
        guard !animation.frames.isEmpty, !isPlayingSleep || timer == nil else { return }
        timer?.cancel()
        timer = nil
        isPlayingSleep = true
        frames = animation.frames
        frameDurations = []
        sleepPoseWeights = animation.poseWeights
        currentSleepPoseIndex = chooseSleepPose(excluding: nil)
        view?.setBreathingEnabled(true)
        showSleepPoseAndScheduleNext(crossfade: false)
    }

    @discardableResult
    func playSingleFrame(_ state: AnimationState, frameIndex: Int) -> Bool {
        guard let definition = sheet.animationTable.definition(for: state) else { return false }
        let stateFrames = sheet.frames(for: definition)
        guard stateFrames.indices.contains(frameIndex) else { return false }

        timer?.cancel()
        timer = nil
        isPlayingSleep = false
        currentSleepPoseIndex = nil
        view?.setBreathingEnabled(false)
        currentState = state
        frames = [stateFrames[frameIndex]]
        frameDurations = []
        self.frameIndex = 0
        stateDidChange?(state)
        view?.image = frames[0]
        return true
    }

    func duration(of state: AnimationState) -> TimeInterval? {
        sheet.animationTable.definition(for: state)?.durations.reduce(0, +)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        frames = []
        frameDurations = []
        isPlayingSleep = false
        currentSleepPoseIndex = nil
        view?.setBreathingEnabled(false)
        view?.image = nil
    }

    private func showSleepPoseAndScheduleNext(crossfade: Bool) {
        guard isPlayingSleep,
              let poseIndex = currentSleepPoseIndex,
              frames.indices.contains(poseIndex) else { return }
        view?.setImage(frames[poseIndex], crossfadeDuration: crossfade ? 1.2 : 0)

        let delay = TimeInterval.random(in: sleepHoldRange)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.isPlayingSleep else { return }
            self.timer?.cancel()
            self.timer = nil
            self.currentSleepPoseIndex = self.chooseSleepPose(excluding: poseIndex)
            self.showSleepPoseAndScheduleNext(crossfade: true)
        }
        self.timer = timer
        timer.resume()
    }

    private func chooseSleepPose(excluding excludedIndex: Int?) -> Int? {
        let candidates = frames.indices.filter { $0 != excludedIndex }
        guard !candidates.isEmpty else { return frames.indices.first }
        let total = candidates.reduce(0.0) { partial, index in
            partial + max(sleepPoseWeights.indices.contains(index) ? sleepPoseWeights[index] : 1, 0)
        }
        guard total > 0 else { return candidates.randomElement() }
        var draw = Double.random(in: 0..<total)
        for index in candidates {
            draw -= max(sleepPoseWeights.indices.contains(index) ? sleepPoseWeights[index] : 1, 0)
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

    deinit {
        timer?.cancel()
    }
}
