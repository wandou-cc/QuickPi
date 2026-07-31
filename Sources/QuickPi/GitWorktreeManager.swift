import Foundation

struct GitRepositoryStatus: Equatable, Sendable {
    let branch: String?
    let upstream: String?
    let additions: Int
    let deletions: Int
    let changedFileCount: Int
    let hasStagedChanges: Bool
    let hasUnstagedChanges: Bool
    let canPush: Bool

    var hasChanges: Bool {
        hasStagedChanges || hasUnstagedChanges
    }
}

struct GitLocalBranch: Identifiable, Equatable, Sendable {
    let name: String
    let isCurrent: Bool

    var id: String { name }
}

struct GitDiffSnapshot: Equatable, Sendable {
    let text: String
    let isTruncated: Bool
    let untrackedFiles: [String]
    let untrackedFileCount: Int
}

struct GitLogEntry: Identifiable, Equatable, Sendable {
    let commitID: String
    let shortCommitID: String
    let date: String
    let author: String
    let subject: String

    var id: String { commitID }
}

struct GitWorktreeManager {
    private struct GitResult {
        let output: Data
        let error: Data
        let status: Int32
    }

    private final class GitOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        // Stores one complete process stream read by a background queue.
        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        // Returns the captured stream after its reader has completed.
        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private let worktreesDirectory: URL

    // Stores app-managed checkouts outside the user's repository.
    init(applicationSupportDirectory: URL) {
        worktreesDirectory = applicationSupportDirectory.appendingPathComponent("worktrees", isDirectory: true)
    }

    // Distinguishes an ordinary selected directory from a valid Git working tree.
    func isGitRepository(at workspaceURL: URL) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let result = try Self.runGit(
                ["-C", workspaceURL.path, "rev-parse", "--is-inside-work-tree"],
                allowedExitCodes: [0, 128]
            )
            if result.status == 0 {
                let value = try Self.utf8Text(result.output, operation: "Git 仓库状态读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard value == "true" || value == "false" else {
                    throw QuickPiError.message("Git 返回了未知的工作树状态：\(value)")
                }
                return value == "true"
            }

            let detail = try Self.utf8Text(result.error, operation: "Git 错误读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard detail.contains("not a git repository") else {
                throw QuickPiError.message(detail.isEmpty ? "Git 仓库识别失败" : detail)
            }
            return false
        }.value
    }

    // Reads the active repository state displayed by the native Git action menu.
    func repositoryStatus(at workspaceURL: URL) async throws -> GitRepositoryStatus {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try await Task.detached(priority: .utility) {
            try Self.requireRepository(at: workspacePath)

            let branchResult = try Self.runGit(
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            let branch: String?
            if branchResult.status == 0 {
                let value = try Self.utf8Text(branchResult.output, operation: "Git 分支读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw QuickPiError.message("Git 返回了空分支名")
                }
                branch = value
            } else {
                branch = nil
            }

            let headResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--verify", "HEAD"],
                allowedExitCodes: [0, 128]
            )
            let stagedResult = try Self.runGit(
                ["-C", workspacePath, "diff", "--cached", "--quiet", "--exit-code"],
                allowedExitCodes: [0, 1]
            )
            let unstagedResult = try Self.runGit(
                ["-C", workspacePath, "diff", "--quiet", "--exit-code"],
                allowedExitCodes: [0, 1]
            )
            let untrackedResult = try Self.runGit([
                "-C", workspacePath,
                "ls-files", "--others", "--exclude-standard", "-z",
            ])
            let statusText = try Self.utf8Text(
                try Self.runGit([
                    "-C", workspacePath,
                    "status", "--porcelain=v1", "--untracked-files=all",
                ]).output,
                operation: "Git 改动状态读取"
            )

            var additions = 0
            var deletions = 0
            if headResult.status == 0 {
                let numstatText = try Self.utf8Text(
                    try Self.runGit(["-C", workspacePath, "diff", "--numstat", "HEAD"]).output,
                    operation: "Git 行变更统计读取"
                )
                for line in numstatText.split(whereSeparator: \.isNewline) {
                    let fields = line.split(
                        separator: "\t",
                        maxSplits: 2,
                        omittingEmptySubsequences: false
                    )
                    guard fields.count >= 2 else {
                        throw QuickPiError.message("Git 返回了无效的行变更统计")
                    }
                    if fields[0] != "-" {
                        guard let value = Int(fields[0]) else {
                            throw QuickPiError.message("Git 返回了无效的新增行数")
                        }
                        additions += value
                    }
                    if fields[1] != "-" {
                        guard let value = Int(fields[1]) else {
                            throw QuickPiError.message("Git 返回了无效的删除行数")
                        }
                        deletions += value
                    }
                }
            }

            let upstreamResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                allowedExitCodes: [0, 128]
            )
            let upstream: String?
            if upstreamResult.status == 0 {
                let value = try Self.utf8Text(upstreamResult.output, operation: "Git 上游分支读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw QuickPiError.message("Git 返回了空上游分支")
                }
                upstream = value
            } else {
                upstream = nil
            }
            let hasConfiguredUpstream: Bool
            if let branch {
                let remoteConfiguration = try Self.runGit(
                    ["-C", workspacePath, "config", "--get", "branch.\(branch).remote"],
                    allowedExitCodes: [0, 1]
                )
                let mergeConfiguration = try Self.runGit(
                    ["-C", workspacePath, "config", "--get", "branch.\(branch).merge"],
                    allowedExitCodes: [0, 1]
                )
                hasConfiguredUpstream = remoteConfiguration.status == 0 || mergeConfiguration.status == 0
            } else {
                hasConfiguredUpstream = false
            }
            let originResult = try Self.runGit(
                ["-C", workspacePath, "remote", "get-url", "--push", "origin"],
                allowedExitCodes: [0, 2, 128]
            )
            let origin = try Self.utf8Text(originResult.output, operation: "Git origin 读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasOrigin = originResult.status == 0
                && !origin.isEmpty

            return GitRepositoryStatus(
                branch: branch,
                upstream: upstream,
                additions: additions,
                deletions: deletions,
                changedFileCount: statusText.split(whereSeparator: \.isNewline).count,
                hasStagedChanges: stagedResult.status == 1,
                hasUnstagedChanges: unstagedResult.status == 1 || !untrackedResult.output.isEmpty,
                canPush: headResult.status == 0
                    && branch != nil
                    && (upstream != nil || (!hasConfiguredUpstream && hasOrigin))
            )
        }.value
    }

    // Lists local branches and marks the branch currently checked out in this worktree.
    func localBranches(at workspaceURL: URL) async throws -> [GitLocalBranch] {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try await Task.detached(priority: .utility) {
            try Self.requireRepository(at: workspacePath)
            let currentResult = try Self.runGit(
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            let currentBranch = currentResult.status == 0
                ? try Self.utf8Text(currentResult.output, operation: "Git 当前分支读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let text = try Self.utf8Text(
                try Self.runGit([
                    "-C", workspacePath,
                    "for-each-ref", "--sort=refname", "--format=%(refname:short)", "refs/heads/",
                ]).output,
                operation: "Git 本地分支读取"
            )
            return text.split(whereSeparator: \.isNewline).map { value in
                let name = String(value)
                return GitLocalBranch(name: name, isCurrent: name == currentBranch)
            }
        }.value
    }

    // Reads tracked changes and a bounded list of untracked files for the Diff view.
    func diff(at workspaceURL: URL) async throws -> GitDiffSnapshot {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try await Task.detached(priority: .utility) {
            try Self.requireRepository(at: workspacePath)
            let headResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--verify", "HEAD"],
                allowedExitCodes: [0, 128]
            )
            let diffData: Data
            if headResult.status == 0 {
                diffData = try Self.runGit([
                    "-C", workspacePath,
                    "diff", "--no-ext-diff", "--no-color", "HEAD", "--",
                ]).output
            } else {
                let staged = try Self.runGit([
                    "-C", workspacePath,
                    "diff", "--cached", "--no-ext-diff", "--no-color", "--",
                ]).output
                let unstaged = try Self.runGit([
                    "-C", workspacePath,
                    "diff", "--no-ext-diff", "--no-color", "--",
                ]).output
                diffData = staged + unstaged
            }
            let completeText = try Self.utf8Text(diffData, operation: "Git Diff 读取")
            let isTruncated = completeText.count > 200_000
            let displayedText = isTruncated ? String(completeText.prefix(200_000)) : completeText

            let untrackedData = try Self.runGit([
                "-C", workspacePath,
                "ls-files", "--others", "--exclude-standard", "-z",
            ]).output
            var untrackedFiles: [String] = []
            for rawPath in untrackedData.split(separator: 0, omittingEmptySubsequences: true) {
                guard let path = String(data: rawPath, encoding: .utf8) else {
                    throw QuickPiError.message("Git 未跟踪文件路径返回了无效 UTF-8")
                }
                untrackedFiles.append(path)
            }

            return GitDiffSnapshot(
                text: displayedText,
                isTruncated: isTruncated,
                untrackedFiles: Array(untrackedFiles.prefix(500)),
                untrackedFileCount: untrackedFiles.count
            )
        }.value
    }

    // Reads the 30 newest commits without invoking a pager or parsing localized Git output.
    func recentCommits(at workspaceURL: URL) async throws -> [GitLogEntry] {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try await Task.detached(priority: .utility) {
            try Self.requireRepository(at: workspacePath)
            let headResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--verify", "HEAD"],
                allowedExitCodes: [0, 128]
            )
            guard headResult.status == 0 else {
                return []
            }
            let data = try Self.runGit([
                "-C", workspacePath,
                "log", "-n", "30", "--date=short",
                "--pretty=format:%H%x00%h%x00%ad%x00%an%x00%s%x00",
            ]).output
            guard !data.isEmpty else {
                return []
            }
            let text = try Self.utf8Text(data, operation: "Git Log 读取")
            var fields = text.components(separatedBy: "\0")
            if fields.last == "" {
                fields.removeLast()
            }
            guard fields.count.isMultiple(of: 5) else {
                throw QuickPiError.message("Git Log 返回了无效记录")
            }
            return stride(from: 0, to: fields.count, by: 5).map { index in
                GitLogEntry(
                    commitID: fields[index],
                    shortCommitID: fields[index + 1],
                    date: fields[index + 2],
                    author: fields[index + 3],
                    subject: fields[index + 4]
                )
            }
        }.value
    }

    // Builds the exact repository context used when the selected model writes a commit message.
    func commitMessageContext(includingUnstaged: Bool, at workspaceURL: URL) async throws -> String {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireRepository(at: workspacePath)

            let headResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--verify", "HEAD"],
                allowedExitCodes: [0, 128]
            )
            let stagedResult = try Self.runGit(
                ["-C", workspacePath, "diff", "--cached", "--quiet", "--exit-code"],
                allowedExitCodes: [0, 1]
            )
            let statusData = try Self.runGit(
                includingUnstaged
                    ? [
                        "-C", workspacePath,
                        "status", "--short", "--untracked-files=all",
                    ]
                    : [
                        "-C", workspacePath,
                        "diff", "--cached", "--name-status", "--",
                    ]
            ).output
            if includingUnstaged {
                guard !statusData.isEmpty else {
                    throw QuickPiError.message("没有可提交的 Git 更改")
                }
            } else {
                guard stagedResult.status == 1 else {
                    throw QuickPiError.message("没有可提交的暂存更改")
                }
            }

            let diffData: Data
            if includingUnstaged {
                if headResult.status == 0 {
                    diffData = try Self.runGit([
                        "-C", workspacePath,
                        "diff", "--no-ext-diff", "--no-color", "HEAD", "--",
                    ]).output
                } else {
                    let staged = try Self.runGit([
                        "-C", workspacePath,
                        "diff", "--cached", "--no-ext-diff", "--no-color", "--",
                    ]).output
                    let unstaged = try Self.runGit([
                        "-C", workspacePath,
                        "diff", "--no-ext-diff", "--no-color", "--",
                    ]).output
                    diffData = staged + unstaged
                }
            } else {
                diffData = try Self.runGit([
                    "-C", workspacePath,
                    "diff", "--cached", "--no-ext-diff", "--no-color", "--",
                ]).output
            }

            let repositoryRootText = try Self.utf8Text(
                try Self.runGit(["-C", workspacePath, "rev-parse", "--show-toplevel"]).output,
                operation: "Git 仓库根目录读取"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repositoryRootText.isEmpty else {
                throw QuickPiError.message("Git 返回了空仓库根目录")
            }
            let repositoryRoot = URL(fileURLWithPath: repositoryRootText, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()

            let branchResult = try Self.runGit(
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            let branch: String
            if branchResult.status == 0 {
                branch = try Self.utf8Text(branchResult.output, operation: "Git 分支读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else {
                    throw QuickPiError.message("Git 返回了空分支名")
                }
            } else {
                branch = "detached HEAD"
            }
            let logText: String
            if headResult.status == 0 {
                let completeLog = try Self.utf8Text(
                    try Self.runGit([
                        "-C", workspacePath,
                        "log", "-n", "20", "--pretty=format:%s",
                    ]).output,
                    operation: "Git 提交标题读取"
                )
                logText = completeLog.count > 8_000
                    ? String(completeLog.prefix(8_000)) + "\n[提交标题已截断]"
                    : completeLog
            } else {
                logText = "（当前仓库还没有提交记录）"
            }

            let completeDiff = try Self.utf8Text(diffData, operation: "Git 提交 Diff 读取")
            let diffLimit = 60_000
            let displayedDiff = completeDiff.count > diffLimit
                ? String(completeDiff.prefix(diffLimit))
                    + "\n[Diff 已截断，仅提供前 \(diffLimit) 个字符]"
                : completeDiff
            let completeStatus = try Self.utf8Text(statusData, operation: "Git 提交状态读取")
            let statusText = completeStatus.count > 15_000
                ? String(completeStatus.prefix(15_000)) + "\n[Git 状态已截断]"
                : completeStatus
            let validation = try Self.commitValidationContext(
                repositoryRoot: repositoryRoot,
                workspacePath: workspacePath
            )

            return """
            项目：\(repositoryRoot.lastPathComponent)
            当前分支：\(branch)
            提交范围：\(includingUnstaged ? "全部工作树更改" : "仅暂存区更改")

            Git 校验与提交约定：
            \(validation)

            最近提交标题：
            \(logText)

            当前 Git 状态：
            \(statusText)

            待提交 Diff：
            \(displayedDiff.isEmpty ? "（没有可展示的已跟踪文件 Diff，请结合 Git 状态中的未跟踪文件判断）" : displayedDiff)
            """
        }.value
    }

    // Creates one commit, optionally staging every tracked and untracked change first.
    func commit(message: String, includingUnstaged: Bool, at workspaceURL: URL) async throws -> String {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commitMessage.isEmpty else {
            throw QuickPiError.message("请输入提交信息")
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireRepository(at: workspacePath)
            if includingUnstaged {
                _ = try Self.runGit(["-C", workspacePath, "add", "--all"])
            }
            let stagedResult = try Self.runGit(
                ["-C", workspacePath, "diff", "--cached", "--quiet", "--exit-code"],
                allowedExitCodes: [0, 1]
            )
            guard stagedResult.status == 1 else {
                throw QuickPiError.message("没有可提交的暂存更改")
            }
            _ = try Self.runGit(["-C", workspacePath, "commit", "-m", commitMessage])
            return try Self.utf8Text(
                try Self.runGit(["-C", workspacePath, "rev-parse", "--short=12", "HEAD"]).output,
                operation: "Git 提交 ID 读取"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    // Pushes the current branch through its upstream or establishes origin as its first upstream.
    func push(at workspaceURL: URL) async throws {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        try await Task.detached(priority: .userInitiated) {
            try Self.requireRepository(at: workspacePath)
            let branchResult = try Self.runGit(
                ["-C", workspacePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            guard branchResult.status == 0 else {
                throw QuickPiError.message("detached HEAD 不能直接推送，请先创建分支")
            }
            let branch = try Self.utf8Text(branchResult.output, operation: "Git 分支读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else {
                throw QuickPiError.message("Git 返回了空分支名")
            }
            _ = try Self.runGit(["-C", workspacePath, "rev-parse", "--verify", "HEAD"])

            let upstreamResult = try Self.runGit(
                ["-C", workspacePath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                allowedExitCodes: [0, 128]
            )
            if upstreamResult.status == 0 {
                _ = try Self.runGit(["-C", workspacePath, "push"])
                return
            }

            let remoteConfiguration = try Self.runGit(
                ["-C", workspacePath, "config", "--get", "branch.\(branch).remote"],
                allowedExitCodes: [0, 1]
            )
            let mergeConfiguration = try Self.runGit(
                ["-C", workspacePath, "config", "--get", "branch.\(branch).merge"],
                allowedExitCodes: [0, 1]
            )
            if remoteConfiguration.status == 0 || mergeConfiguration.status == 0 {
                let detail = try Self.utf8Text(upstreamResult.error, operation: "Git 上游分支错误读取")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw QuickPiError.message(detail.isEmpty ? "Git 上游分支配置无效" : detail)
            }

            let originResult = try Self.runGit(
                ["-C", workspacePath, "remote", "get-url", "--push", "origin"],
                allowedExitCodes: [0, 2, 128]
            )
            guard originResult.status == 0 else {
                throw QuickPiError.message("当前分支没有上游，且仓库未配置 origin")
            }
            _ = try Self.runGit([
                "-C", workspacePath,
                "push", "--set-upstream", "origin", branch,
            ])
        }.value
    }

    // Creates and checks out one validated local branch in the active working tree.
    func createBranch(named name: String, at workspaceURL: URL) async throws -> String {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else {
            throw QuickPiError.message("请输入分支名称")
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireRepository(at: workspacePath)
            _ = try Self.runGit(["check-ref-format", "--branch", branchName])
            _ = try Self.runGit(["-C", workspacePath, "switch", "-c", branchName])
            return branchName
        }.value
    }

    // Switches the active working tree to one exact local branch selected from Git's branch list.
    func switchBranch(named name: String, at workspaceURL: URL) async throws {
        let workspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        try await Task.detached(priority: .userInitiated) {
            try Self.requireRepository(at: workspacePath)
            _ = try Self.runGit(["check-ref-format", "--branch", name])
            _ = try Self.runGit(["-C", workspacePath, "switch", name])
        }.value
    }

    // Creates a detached worktree at HEAD and applies the source checkout's non-ignored local changes.
    func create(sessionID: String, workspaceURL: URL) async throws -> ManagedWorktree {
        let worktreesDirectory = worktreesDirectory
        return try await Task.detached(priority: .userInitiated) {
            try Self.createSynchronously(
                sessionID: sessionID,
                workspaceURL: workspaceURL,
                worktreesDirectory: worktreesDirectory
            )
        }.value
    }

    // Reads the branch currently checked out by Git, returning nil only for a valid detached HEAD.
    func currentBranch(in worktree: ManagedWorktree) async throws -> String? {
        try await Task.detached(priority: .utility) {
            let result = try Self.runGit(
                ["-C", worktree.worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            guard result.status == 0 else {
                return nil
            }
            let branch = try Self.utf8Text(result.output, operation: "Git 分支读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else {
                throw QuickPiError.message("Git 返回了空分支名")
            }
            return branch
        }.value
    }

    // Refuses cleanup while tracked or untracked user changes remain in the managed checkout.
    func validateRemoval(of worktree: ManagedWorktree) async throws {
        try await Task.detached(priority: .userInitiated) {
            let status = try Self.runGit([
                "-C", worktree.worktreePath,
                "status", "--porcelain=v1", "--untracked-files=all",
            ])
            guard status.output.isEmpty else {
                throw QuickPiError.message(
                    "Worktree 仍有未提交改动，已取消清理：\(worktree.workspacePath)"
                )
            }
        }.value
    }

    // Preserves commits made on a detached HEAD before its worktree reference is removed.
    func preserveDetachedHead(of worktree: ManagedWorktree) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            let branchResult = try Self.runGit(
                ["-C", worktree.worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"],
                allowedExitCodes: [0, 1]
            )
            if branchResult.status == 0 {
                return nil
            }

            let head = try Self.utf8Text(
                try Self.runGit(["-C", worktree.worktreePath, "rev-parse", "--verify", "HEAD"]).output,
                operation: "Git HEAD 读取"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard head != worktree.baseCommit else {
                return nil
            }

            let branch = "quick-pi/\(worktree.id.lowercased())"
            let existing = try Self.runGit(
                ["-C", worktree.repositoryPath, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                allowedExitCodes: [0, 1]
            )
            if existing.status == 0 {
                let existingHead = try Self.utf8Text(
                    try Self.runGit(["-C", worktree.repositoryPath, "rev-parse", "refs/heads/\(branch)"]).output,
                    operation: "Git 保护分支读取"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard existingHead == head else {
                    throw QuickPiError.message("保护分支已存在且指向其他提交：\(branch)")
                }
                return branch
            }
            _ = try Self.runGit(["-C", worktree.repositoryPath, "branch", branch, head])
            return branch
        }.value
    }

    // Removes one validated Git worktree without forcing away user data.
    func remove(_ worktree: ManagedWorktree) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try Self.runGit([
                "-C", worktree.repositoryPath,
                "worktree", "remove", worktree.worktreePath,
            ])
        }.value
    }

    // Rolls back a newly created worktree whose Pi session never became usable.
    func discardNew(_ worktree: ManagedWorktree) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try Self.runGit([
                "-C", worktree.repositoryPath,
                "worktree", "remove", "--force", worktree.worktreePath,
            ])
        }.value
    }

    // Performs the blocking Git and file-copy transaction away from the main actor.
    private static func createSynchronously(
        sessionID: String,
        workspaceURL: URL,
        worktreesDirectory: URL
    ) throws -> ManagedWorktree {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRootText = try utf8Text(
            try runGit(["-C", workspace.path, "rev-parse", "--show-toplevel"]).output,
            operation: "Git 仓库读取"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRoot = URL(fileURLWithPath: sourceRootText, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard workspace.path == sourceRoot.path || workspace.path.hasPrefix(sourceRoot.path + "/") else {
            throw QuickPiError.message("工作区不属于 Git 仓库根目录")
        }

        let worktreeList = try utf8Text(
            try runGit(["-C", sourceRoot.path, "worktree", "list", "--porcelain", "-z"]).output,
            operation: "Git Worktree 列表读取"
        )
        guard let primaryRecord = worktreeList
            .split(separator: "\0", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix("worktree ") }) else {
            throw QuickPiError.message("Git 没有返回主工作树")
        }
        let repositoryPath = String(primaryRecord.dropFirst("worktree ".count))
        let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let baseCommit = try utf8Text(
            try runGit(["-C", sourceRoot.path, "rev-parse", "--verify", "HEAD"]).output,
            operation: "Git HEAD 读取"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let relativeWorkspacePath = workspace.path == sourceRoot.path
            ? ""
            : String(workspace.path.dropFirst(sourceRoot.path.count + 1))

        try FileManager.default.createDirectory(
            at: worktreesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: worktreesDirectory.path
        )
        let worktreeRoot = worktreesDirectory.appendingPathComponent(sessionID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: worktreeRoot.path) else {
            throw QuickPiError.message("Worktree 目录已存在：\(worktreeRoot.path)")
        }

        var worktreeAdded = false
        do {
            _ = try runGit([
                "-C", repository.path,
                "worktree", "add", "--detach", worktreeRoot.path, baseCommit,
            ])
            worktreeAdded = true

            let diff = try runGit([
                "-C", sourceRoot.path,
                "diff", "--binary", "HEAD", "--", ".",
            ]).output
            if !diff.isEmpty {
                _ = try runGit(
                    ["-C", worktreeRoot.path, "apply", "--whitespace=nowarn", "-"],
                    input: diff
                )
            }

            let untracked = try runGit([
                "-C", sourceRoot.path,
                "ls-files", "--others", "--exclude-standard", "-z",
            ]).output
            for rawPath in untracked.split(separator: 0, omittingEmptySubsequences: true) {
                guard let relativePath = String(data: rawPath, encoding: .utf8),
                      !relativePath.hasPrefix("/"),
                      !relativePath.split(separator: "/").contains("..") else {
                    throw QuickPiError.message("Git 返回了无效的未跟踪文件路径")
                }
                let source = sourceRoot.appendingPathComponent(relativePath)
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw QuickPiError.message("Worktree 不复制未跟踪的符号链接：\(relativePath)")
                }
                let destination = worktreeRoot.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }

            let worktreeWorkspace = relativeWorkspacePath.isEmpty
                ? worktreeRoot
                : worktreeRoot.appendingPathComponent(relativeWorkspacePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktreeWorkspace.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw QuickPiError.message("Worktree 中缺少选定的工作区子目录")
            }
            return ManagedWorktree(
                id: sessionID,
                repositoryPath: repository.path,
                localWorkspacePath: workspace.path,
                worktreePath: worktreeRoot.path,
                workspacePath: worktreeWorkspace.path,
                baseCommit: baseCommit,
                createdAt: Date().timeIntervalSince1970,
                branch: nil
            )
        } catch {
            let creationError = error
            if worktreeAdded {
                do {
                    _ = try runGit([
                        "-C", repository.path,
                        "worktree", "remove", "--force", worktreeRoot.path,
                    ])
                } catch {
                    throw QuickPiError.message(
                        "Worktree 创建失败：\(creationError.localizedDescription)\n回滚也失败：\(error.localizedDescription)"
                    )
                }
            } else if FileManager.default.fileExists(atPath: worktreeRoot.path) {
                do {
                    try FileManager.default.removeItem(at: worktreeRoot)
                } catch {
                    throw QuickPiError.message(
                        "Worktree 创建失败：\(creationError.localizedDescription)\n临时目录清理失败：\(error.localizedDescription)"
                    )
                }
            }
            throw creationError
        }
    }

    // Reads commit templates, commit hooks, and common repository validation files without executing them.
    private static func commitValidationContext(
        repositoryRoot: URL,
        workspacePath: String
    ) throws -> String {
        var sections: [String] = []
        var remainingBytes = 20_000

        func appendFile(label: String, url: URL) throws {
            guard remainingBytes > 0,
                  FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                return
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: remainingBytes + 1) ?? Data()
            let truncated = data.count > remainingBytes
            let usedData = data.prefix(remainingBytes)
            let text = usedData.contains(0)
                ? "[二进制文件，未展示内容]"
                : String(decoding: usedData, as: UTF8.self)
            sections.append("[\(label)]\n\(text)\(truncated ? "\n[内容已截断]" : "")")
            remainingBytes -= usedData.count
        }

        let templateResult = try runGit(
            ["-C", workspacePath, "config", "--path", "--get", "commit.template"],
            allowedExitCodes: [0, 1]
        )
        if templateResult.status == 0 {
            let path = try utf8Text(templateResult.output, operation: "Git 提交模板路径读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw QuickPiError.message("Git 返回了空提交模板路径")
            }
            let url = URL(
                fileURLWithPath: path,
                relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true)
            ).standardizedFileURL
            try appendFile(label: "Git commit.template", url: url)
        }

        for hookName in ["pre-commit", "prepare-commit-msg", "commit-msg", "pre-push"] {
            let hookResult = try runGit([
                "-C", workspacePath,
                "rev-parse", "--git-path", "hooks/\(hookName)",
            ])
            let path = try utf8Text(hookResult.output, operation: "Git Hook 路径读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw QuickPiError.message("Git 返回了空 Hook 路径")
            }
            let url = URL(
                fileURLWithPath: path,
                relativeTo: URL(fileURLWithPath: workspacePath, isDirectory: true)
            ).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                continue
            }
            try appendFile(label: "Git hook: \(hookName)", url: url)
        }

        let validationFiles = [
            ".commitlintrc",
            ".commitlintrc.json",
            ".commitlintrc.yaml",
            ".commitlintrc.yml",
            ".commitlintrc.js",
            ".commitlintrc.cjs",
            ".commitlintrc.mjs",
            ".commitlintrc.ts",
            "commitlint.config.js",
            "commitlint.config.cjs",
            "commitlint.config.mjs",
            "commitlint.config.ts",
            ".husky/commit-msg",
            ".husky/pre-commit",
            ".pre-commit-config.yaml",
            ".pre-commit-config.yml",
            "lefthook.yml",
            "lefthook.yaml",
            ".lefthook.yml",
            ".lefthook.yaml",
        ]
        for relativePath in validationFiles {
            try appendFile(
                label: relativePath,
                url: repositoryRoot.appendingPathComponent(relativePath)
            )
        }

        return sections.isEmpty
            ? "未发现 commit.template、提交相关 Git hooks 或常见提交校验配置。"
            : sections.joined(separator: "\n\n")
    }

    // Requires an actual working tree before any repository-specific operation proceeds.
    private static func requireRepository(at workspacePath: String) throws {
        let result = try runGit(
            ["-C", workspacePath, "rev-parse", "--is-inside-work-tree"],
            allowedExitCodes: [0, 128]
        )
        guard result.status == 0,
              try utf8Text(result.output, operation: "Git 仓库状态读取")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw QuickPiError.message("当前会话目录不是 Git 工作树")
        }
    }

    // Runs Git without a shell so branch names and paths cannot become command text.
    private static func runGit(
        _ arguments: [String],
        input: Data? = nil,
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> GitResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = GitOutputCollector()
        let errorCollector = GitOutputCollector()
        let outputFinished = DispatchSemaphore(value: 0)
        let errorFinished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment
        let standardInput: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            standardInput = pipe
        } else {
            standardInput = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            outputCollector.store(standardOutput.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            errorCollector.store(standardError.fileHandleForReading.readDataToEndOfFile())
            errorFinished.signal()
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForWriting.closeFile()
            standardError.fileHandleForWriting.closeFile()
            standardInput?.fileHandleForWriting.closeFile()
            outputFinished.wait()
            errorFinished.wait()
            throw error
        }
        standardOutput.fileHandleForWriting.closeFile()
        standardError.fileHandleForWriting.closeFile()
        var inputError: Error?
        if let input, let standardInput {
            do {
                try standardInput.fileHandleForWriting.write(contentsOf: input)
                try standardInput.fileHandleForWriting.close()
            } catch {
                standardInput.fileHandleForWriting.closeFile()
                inputError = error
            }
        }
        process.waitUntilExit()
        outputFinished.wait()
        errorFinished.wait()
        let output = outputCollector.value()
        let error = errorCollector.value()
        if let inputError {
            throw inputError
        }
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let detail = try utf8Text(error, operation: "Git 错误读取")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw QuickPiError.message(detail.isEmpty ? "Git 命令执行失败" : detail)
        }
        return GitResult(output: output, error: error, status: process.terminationStatus)
    }

    // Requires Git path and diagnostic output to use valid UTF-8 on macOS.
    private static func utf8Text(_ data: Data, operation: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuickPiError.message("\(operation)返回了无效 UTF-8")
        }
        return text
    }
}
