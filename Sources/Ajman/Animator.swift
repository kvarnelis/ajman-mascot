import AppKit

final class Animator {
    private var sheet: SpriteSheet
    private weak var view: PetView?
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var frameDurations: [TimeInterval] = []
    private var frameIndex = 0

    private(set) var currentState: AnimationState = .idle
    private(set) var isPlayingSleep = false
    var stateDidChange: ((AnimationState) -> Void)?
    var availableStates: [AnimationState] { sheet.animationTable.states }

    init(sheet: SpriteSheet, view: PetView?) {
        self.sheet = sheet
        self.view = view
    }

    func replaceSheet(_ sheet: SpriteSheet, playing state: AnimationState) {
        timer?.cancel()
        timer = nil
        frames = []
        frameDurations = []
        frameIndex = 0
        self.sheet = sheet
        isPlayingSleep = false
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
        frameDurations = Array(repeating: SleepAnimation.frameDuration, count: frames.count)
        frameIndex = 0
        showCurrentFrameAndScheduleNext()
    }

    @discardableResult
    func playSingleFrame(_ state: AnimationState, frameIndex: Int) -> Bool {
        guard let definition = sheet.animationTable.definition(for: state) else { return false }
        let stateFrames = sheet.frames(for: definition)
        guard stateFrames.indices.contains(frameIndex) else { return false }

        timer?.cancel()
        timer = nil
        isPlayingSleep = false
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
        view?.image = nil
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
