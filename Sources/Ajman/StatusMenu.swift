import AppKit

final class StatusMenu: NSObject {
    private let animator: Animator
    private weak var panel: OverlayPanel?
    private let statusItem: NSStatusItem
    private let cycleItem = NSMenuItem(title: "Cycle All States", action: #selector(toggleCycle(_:)), keyEquivalent: "")
    private var stateItems: [AnimationState: NSMenuItem] = [:]
    private var cycleTimer: Timer?

    init(animator: Animator, panel: OverlayPanel) {
        self.animator = animator
        self.panel = panel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        for state in animator.availableStates {
            let item = NSMenuItem(title: state.title, action: #selector(selectState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            menu.addItem(item)
            stateItems[state] = item
        }
        menu.addItem(.separator())
        cycleItem.target = self
        menu.addItem(cycleItem)

        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Ajman", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        animator.stateDidChange = { [weak self] state in self?.updateChecks(for: state) }
        updateChecks(for: animator.currentState)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        stopCycling()
        guard let rawValue = sender.representedObject as? String,
              let state = AnimationState(rawValue: rawValue) else { return }
        animator.play(state)
    }

    @objc private func toggleCycle(_ sender: NSMenuItem) {
        cycleTimer == nil ? startCycling() : stopCycling()
    }

    private func startCycling() {
        cycleItem.state = .on
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self,
                  let index = self.animator.availableStates.firstIndex(of: self.animator.currentState) else { return }
            let states = self.animator.availableStates
            self.animator.play(states[(index + 1) % states.count])
        }
    }

    private func stopCycling() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        cycleItem.state = .off
    }

    private func updateChecks(for state: AnimationState) {
        for (candidate, item) in stateItems { item.state = candidate == state ? .on : .off }
    }

    @objc private func resetPosition() { panel?.resetPosition() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
