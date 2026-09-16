import Darwin
import Foundation

public final class TerminalPTYTransport: @unchecked Sendable {
  private let queueKey = DispatchSpecificKey<UInt8>()
  public struct Exit: Sendable {
    public let code: Int32?
    public let signal: Int32?
  }

  let queue = DispatchQueue(label: "com.webstudio.terminal-pty-transport", qos: .userInitiated)
  var onStart: ((Bool, String?) -> Void)?
  var onOutput: ((Data) -> Void)?
  var onExit: ((Exit) -> Void)?
  var onError: ((String) -> Void)?

  private let inputLimit = 256 * 1024
  private let admissionLock = NSLock()
  private var reservedInput = 0
  private var acceptingInput = true
  private var started = false
  private var closing = false
  private var finished = false
  private var leaderPID: pid_t = -1
  private var sessionID: pid_t = -1
  private var leaderExited = false
  private var leaderReaped = false
  private var ownedGroup: pid_t = -1
  private var fd: Int32 = -1
  private var nonblockingConfigured = false
  private var input = Data()
  private var exit: Exit?
  private var readClosed = false
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var reapSource: DispatchSourceTimer?
  private var killSource: DispatchSourceTimer?
  private var activeSources = 0
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeFDWhenSourcesCancel = false
  private var closeEscalationCompleted = false
  private var killEscalationSent = false
  private var closeGroups: [pid_t] = []
  private var closeGroupDiscoveryFailureReported = false
  private var exitDelivered = false

  init() { queue.setSpecific(key: queueKey, value: 1) }

  func start(
    executable: String, argv: [String], environment: [String: String], directory: String?,
    columns: Int, rows: Int, widthPixels: Int = 0, heightPixels: Int = 0
  ) {
    queue.async { [self] in
      guard !started else {
        onError?("PTY transport can only be started once")
        return
      }
      started = true
      guard !closing, !finished else {
        finish(Exit(code: nil, signal: nil))
        return
      }
      var args = argv.map { strdup($0) } + [nil]
      var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      let result = args.withUnsafeMutableBufferPointer { ab in
        env.withUnsafeMutableBufferPointer { eb in
          executable.withCString { exe in
            (directory ?? "").withCString { dir in
              studio_pty_spawn_pixels(
                exe, ab.baseAddress!, eb.baseAddress!, directory == nil ? nil : dir,
                UInt16(clamping: columns), UInt16(clamping: rows), UInt32(clamping: widthPixels), UInt32(clamping: heightPixels))
            }
          }
        }
      }
      args.dropLast().forEach { free(UnsafeMutableRawPointer($0)) }
      env.dropLast().forEach { free(UnsafeMutableRawPointer($0)) }
      guard result.pid > 0, result.master_fd >= 0 else {
        if result.master_fd >= 0 { _ = studio_pty_close(result.master_fd) }
        let detail =
          result.error_number > 0 ? String(cString: strerror(result.error_number)) : "unknown error"
        let message = "PTY start failed (stage \(result.error_stage)): \(detail)"
        onStart?(false, message)
        onError?(message)
        finish(Exit(code: nil, signal: nil))
        return
      }
      leaderPID = result.pid
      sessionID = getsid(result.pid)
      fd = result.master_fd
      ownedGroup = result.pid
      if let foreground = validForegroundGroup(for: result.pid), foreground != result.pid {
        ownedGroup = foreground
      }
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        let message = "Unable to configure nonblocking PTY: \(String(cString: strerror(errno)))"
        onStart?(false, message)
        onError?(message)
        requestClose()
        return
      }
      nonblockingConfigured = true
      installReadSource()
      beginReaping()
      onStart?(true, nil)
    }
  }

  @discardableResult
  func write(_ data: Data) -> Bool {
    admissionLock.lock()
    guard acceptingInput, data.count <= inputLimit - reservedInput else {
      admissionLock.unlock()
      return false
    }
    reservedInput += data.count
    admissionLock.unlock()
    queue.async { [self] in
      guard !closing, !finished, fd >= 0, leaderPID > 0 else {
        releaseAdmission(data.count)
        return
      }
      input.append(data)
      drainWrites()
    }
    return true
  }

  func resize(columns: Int, rows: Int, widthPixels: Int = 0, heightPixels: Int = 0) {
    queue.async { [self] in
      guard fd >= 0, !finished else { return }
      guard (1...Int(UInt16.max)).contains(columns), (1...Int(UInt16.max)).contains(rows),
        (0...Int(UInt16.max)).contains(widthPixels), (0...Int(UInt16.max)).contains(heightPixels)
      else {
        onError?("Invalid PTY size")
        return
      }
      let result = studio_pty_resize_pixels(
        fd, UInt16(clamping: columns), UInt16(clamping: rows), UInt32(clamping: widthPixels),
        UInt32(clamping: heightPixels))
      if result != 0 { onError?("Unable to resize PTY: \(String(cString: strerror(errno)))") }
    }
  }

  func close() { queue.async { [self] in requestClose() } }

  func closeAndWait() async {
    return await withCheckedContinuation { continuation in
      queue.async { [self] in
        if finished && exitDelivered {
          continuation.resume()
        } else {
          closeWaiters.append(continuation)
          requestClose()
        }
      }
    }
  }

  func currentPID() -> pid_t? {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return leaderPID > 0 && !leaderExited && !finished ? leaderPID : nil
    }
    return queue.sync { leaderPID > 0 && !leaderExited && !finished ? leaderPID : nil }
  }

  private func requestClose() {
    guard !finished, !closing else { return }
    closing = true
    closeEscalationCompleted = false
    killEscalationSent = false
    closeGroupDiscoveryFailureReported = false
    admissionLock.lock()
    acceptingInput = false
    admissionLock.unlock()
    input.removeAll(keepingCapacity: false)
    releaseAdmissionAll()
    cancelWriteSource()
    if fd >= 0 {
      if !nonblockingConfigured {
        refreshCloseGroups()
        _ = studio_pty_close(fd); fd = -1
        signalOwnedGroup(SIGTERM)
        armKillTimer()
        beginReaping()
        return
      }
      if let foreground = validForegroundGroup(for: leaderPID) { ownedGroup = foreground }
      refreshCloseGroups()
      signalOwnedGroup(SIGHUP)
      signalOwnedGroup(SIGTERM)
      armKillTimer()
      readAvailable(drain: true)
    } else if leaderPID > 0 {
      refreshCloseGroups()
      signalOwnedGroup(SIGTERM)
      armKillTimer()
      readAvailable(drain: true)
    } else {
      finish(Exit(code: nil, signal: nil))
    }
  }

  private func installReadSource() {
    activeSources += 1
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.readAvailable(drain: false) }
    source.setCancelHandler { [weak self] in
      self?.sourceCancelled()
    }
    readSource = source
    source.resume()
  }

  private func installWriteSource() {
    guard writeSource == nil, fd >= 0 else { return }
    activeSources += 1
    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drainWrites() }
    source.setCancelHandler { [weak self] in
      self?.sourceCancelled()
    }
    writeSource = source
    source.resume()
  }

  private func cancelReadSource() {
    guard let source = readSource else {
      maybeCloseFD()
      return
    }
    readSource = nil
    source.cancel()
  }

  private func cancelWriteSource() {
    guard let source = writeSource else {
      maybeCloseFD()
      return
    }
    writeSource = nil
    source.cancel()
  }

  private func sourceCancelled() {
    activeSources = max(0, activeSources - 1)
    maybeCloseFD()
  }

  private func drainWrites() {
    guard fd >= 0, !closing, !finished else { return }
    while !input.isEmpty {
      let count = min(input.count, 32 * 1024)
      let result = input.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, count) }
      if result > 0 {
        input.removeFirst(result)
        releaseAdmission(result)
      } else if result < 0, errno == EINTR {
        continue
      } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        installWriteSource()
        return
      } else {
        onError?("PTY write failed: \(String(cString: strerror(errno)))")
        input.removeAll()
        releaseAdmissionAll()
        requestClose()
        return
      }
    }
    cancelWriteSource()
  }

  private func readAvailable(drain: Bool) {
    guard fd >= 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 32 * 1024)
    var reads = 0
    while true {
      let result = Darwin.read(fd, &bytes, bytes.count)
      if result > 0 {
        onOutput?(Data(bytes.prefix(result)))
        reads += 1
        if !drain || reads >= 8 { return }
        continue
      }
      if result < 0, errno == EINTR { continue }
      if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
      readClosed = true
      cancelReadSource()
      maybeFinish()
      return
    }
  }

  private func beginReaping() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.reap() }
    reapSource = timer
    timer.resume()
  }

  private func reap() {
    guard leaderPID > 0, !leaderExited else {
      maybeFinish()
      return
    }
    var status: Int32 = 0
    let result = studio_pty_peek_exit(leaderPID, &status)
    if result == 1 {
      leaderExited = true
      var didExit: Int32 = 0
      let code = studio_pty_exit_code(status, &didExit)
      let signal = studio_pty_signal_code(status)
      exit = Exit(code: didExit == 1 ? Int32(code) : nil, signal: signal > 0 ? Int32(signal) : nil)
      // A session leader can exit while descendants keep the session alive.
      // Enter the same bounded, ownership-checked cleanup path before the
      // exit callback so no background job outlives a natural exit.
      if !closing { requestClose() }
      if fd >= 0 { readAvailable(drain: true) }
      maybeFinish()
    } else if result < 0, errno == ECHILD {
      leaderExited = true
      exit = Exit(code: nil, signal: nil)
      if !closing { requestClose() }
      maybeFinish()
    }
  }

  private func armKillTimer() {
    killSource?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(350))
    timer.setEventHandler { [weak self] in
      guard let self, !self.finished else { return }
      if !self.killEscalationSent {
        // Kill all owned groups together. Waiting for a foreground child
        // before killing a resistant session leader would deadlock because
        // the leader may never reap that child.
        self.killEscalationSent = true
      }
      // Descendants can create a new process group while escalation is in
      // progress. Re-discovery plus per-group C validation keeps retries
      // ownership-safe even when a group ID has been reused.
      _ = self.refreshCloseGroups()
      self.signalOwnedGroup(SIGKILL)
      self.readAvailable(drain: true)
      if !self.readClosed {
        self.readClosed = true
        self.cancelReadSource()
      }
      self.killSource?.cancel()
      self.killSource = nil
      self.reap()
      self.observeCloseGroups()
      if !self.closeEscalationCompleted { self.armKillTimer() }
    }
    killSource = timer
    timer.resume()
  }

  private func maybeFinish() {
    guard leaderExited else { return }
    if closing && !closeEscalationCompleted {
      // SIGKILL is the final group-wide escalation.  Completion waits for the
      // leader's observed exit and this escalation, while avoiding a second
      // signal after the group leader has disappeared and a PID is reused.
      guard killEscalationSent else { return }
      observeCloseGroups()
      guard closeEscalationCompleted else { return }
    }
    if !readClosed, fd >= 0 { readAvailable(drain: true) }
    guard readClosed || fd < 0 else { return }
    if !leaderReaped {
      var status: Int32 = 0
      var result: pid_t
      repeat { result = waitpid(leaderPID, &status, WNOHANG) } while result < 0 && errno == EINTR
      guard result == leaderPID || (result < 0 && errno == ECHILD) else { return }
      leaderReaped = true
    }
    finish(exit ?? Exit(code: nil, signal: nil))
  }

  private func observeCloseGroups() {
    guard closing, killEscalationSent, sessionID > 0 else { return }
    guard refreshCloseGroups() else { return }
    guard !closeGroups.isEmpty else { closeEscalationCompleted = true; return }
    for group in closeGroups {
      let result = studio_pty_group_has_session_members_except(group, sessionID, leaderPID)
      if result < 0, errno != ESRCH, errno != EPERM { return }
      if result > 0 { return }
    }
    closeEscalationCompleted = true
  }

  private func finish(_ result: Exit) {
    guard !finished else { return }
    exit = result
    finished = true
    admissionLock.lock()
    acceptingInput = false
    admissionLock.unlock()
    input.removeAll(keepingCapacity: false)
    releaseAdmissionAll()
    reapSource?.cancel()
    reapSource = nil
    killSource?.cancel()
    killSource = nil
    cancelWriteSource()
    cancelReadSource()
    closeFDWhenSourcesCancel = true
    maybeCloseFD()
    if fd < 0 { deliverExitIfNeeded() }
    if fd < 0 { resumeCloseWaiters() }
  }

  private func maybeCloseFD() {
    guard closeFDWhenSourcesCancel, activeSources == 0, fd >= 0
    else { return }
    _ = studio_pty_close(fd)
    fd = -1
    closeFDWhenSourcesCancel = false
    if finished { deliverExitIfNeeded() }
    if finished { resumeCloseWaiters() }
  }

  private func deliverExitIfNeeded() {
    guard !exitDelivered, let result = exit else { return }
    exitDelivered = true
    onExit?(result)
  }

  private func resumeCloseWaiters() {
    guard finished, fd < 0, exitDelivered else { return }
    let waiters = closeWaiters
    closeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func validForegroundGroup(for sessionLeader: pid_t) -> pid_t? {
    guard fd >= 0, sessionLeader > 0 else { return nil }
    let foreground = tcgetpgrp(fd)
    guard foreground > 0, getsid(foreground) == getsid(sessionLeader) else { return nil }
    return foreground
  }

  private func signalOwnedGroup(_ signal: Int32) {
    guard sessionID > 0 else { return }
    let targets = closeGroups.isEmpty ? Array(Set([ownedGroup, leaderPID].filter { $0 > 0 })) : closeGroups
    for group in targets {
      let result = studio_pty_signal_group(group, sessionID, signal)
      if result != 0 && errno != ESRCH { onError?("PTY group signal failed (group \(group), signal \(signal)): \(String(cString: strerror(errno)))") }
    }
  }

  @discardableResult
  private func refreshCloseGroups() -> Bool {
    guard sessionID > 0 else { return false }
    var capacity = max(8, closeGroups.count)
    while true {
      var groups = [pid_t](repeating: 0, count: capacity)
      let result = studio_pty_session_groups(sessionID, &groups, groups.count)
      if result >= 0 {
        closeGroups = Array(Set(groups.prefix(Int(result)))).filter { $0 > 0 }
        if ownedGroup > 0 && !closeGroups.contains(ownedGroup) { closeGroups.append(ownedGroup) }
        if leaderPID > 0 && !closeGroups.contains(leaderPID) { closeGroups.append(leaderPID) }
        return true
      }
      if errno != EOVERFLOW {
        if !closeGroupDiscoveryFailureReported {
          closeGroupDiscoveryFailureReported = true
          onError?("PTY session-group discovery failed: \(String(cString: strerror(errno)))")
        }
        return false
      }
      capacity *= 2
    }
  }

  private func releaseAdmission(_ count: Int) {
    admissionLock.lock()
    reservedInput = max(0, reservedInput - count)
    admissionLock.unlock()
  }
  private func releaseAdmissionAll() {
    admissionLock.lock()
    reservedInput = 0
    admissionLock.unlock()
  }
}
