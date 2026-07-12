import AppKit

final class Animator {
    private let sheet: SpriteSheet
    private weak var view: PetView?
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var frameIndex = 0

    private(set) var currentState: AnimationState = .idle
    var stateDidChange: ((AnimationState) -> Void)?
    var availableStates: [AnimationState] { sheet.animationTable.states }

    init(sheet: SpriteSheet, view: PetView) {
        self.sheet = sheet
        self.view = view
    }

    func play(_ state: AnimationState) {
        guard state != currentState || timer == nil else { return }
        guard let definition = sheet.animationTable.definition(for: state) else { return }
        timer?.cancel()
        timer = nil
        currentState = state
        frames = sheet.frames(for: definition)
        frameIndex = 0
        stateDidChange?(state)
        showCurrentFrameAndScheduleNext(definition: definition)
    }

    private func showCurrentFrameAndScheduleNext(definition: AnimationDefinition) {
        guard !frames.isEmpty else { return }
        view?.image = frames[frameIndex]
        let delay = definition.durations[frameIndex]
        let nextIndex = (frameIndex + 1) % frames.count

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.frameIndex = nextIndex
            self.showCurrentFrameAndScheduleNext(definition: definition)
        }
        self.timer = timer
        timer.resume()
    }
}
