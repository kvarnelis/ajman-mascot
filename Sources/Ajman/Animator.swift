import AppKit

final class Animator {
    private let sheet: SpriteSheet
    private weak var view: PetView?
    private var timer: DispatchSourceTimer?
    private var frames: [CGImage] = []
    private var frameIndex = 0

    private(set) var currentState: AnimationState = .idle
    var stateDidChange: ((AnimationState) -> Void)?

    init(sheet: SpriteSheet, view: PetView) {
        precondition(AnimationState.usedFrameCount == 57, "Animation table must use 57 frames")
        self.sheet = sheet
        self.view = view
    }

    func play(_ state: AnimationState) {
        timer?.cancel()
        timer = nil
        currentState = state
        frames = sheet.frames(for: state)
        frameIndex = 0
        stateDidChange?(state)
        showCurrentFrameAndScheduleNext()
    }

    private func showCurrentFrameAndScheduleNext() {
        guard !frames.isEmpty else { return }
        view?.image = frames[frameIndex]
        let delay = currentState.durations[frameIndex]
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
}
