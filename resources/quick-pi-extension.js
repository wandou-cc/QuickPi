import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { complete } from "@earendil-works/pi-ai/compat";
import { SessionManager } from "@earendil-works/pi-coding-agent";

const prefix = "quickpi:";
const commitMessageSystemPrompt = `你负责为当前 Git 项目生成提交信息。先检查用户提供的“Git 校验与提交约定”和最近提交历史；如果项目存在 commit.template、commit-msg、commitlint、Conventional Commits 或其他提交校验，生成结果必须符合这些规则和项目既有风格。然后根据当前 Git 状态和待提交 Diff，生成准确、简洁的提交信息。只输出可以直接用于 git commit 的最终提交信息，不要解释，不要使用 Markdown，不要添加引号。`;

// Reads Pi's credential document; absence is the documented first-launch state.
async function readCredentials(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {};
    }
    throw error;
  }
}

// Atomically writes credentials with the permissions required for API keys and OAuth tokens.
async function writeCredentials(directory, credentials) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const path = join(directory, "auth.json");
  const temporaryPath = `${path}.tmp`;
  await writeFile(temporaryPath, JSON.stringify(credentials, null, 2), { mode: 0o600 });
  await rename(temporaryPath, path);
  await chmod(path, 0o600);
}

// Sends one structured native-app event through Pi's public extension UI channel.
function notify(ctx, payload) {
  ctx.ui.notify(`${prefix}${JSON.stringify(payload)}`, "info");
}

function decodeCommitMessageRequest(value) {
  const encoded = value.trim();
  if (!encoded) {
    throw new Error("缺少提交信息生成请求");
  }
  const request = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  if (typeof request?.requestId !== "string" || !request.requestId) {
    throw new Error("提交信息生成请求缺少 requestId");
  }
  if (typeof request.context !== "string" || !request.context || request.context.length > 200_000) {
    throw new Error("提交信息生成上下文无效");
  }
  return request;
}

async function generateCommitMessage(ctx, context) {
  if (!ctx.model) {
    throw new Error("当前没有已选择的模型");
  }
  const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model);
  if (!auth.ok || !auth.apiKey) {
    throw new Error(auth.ok ? `Provider ${ctx.model.provider} 没有可用凭证` : auth.error);
  }
  const response = await complete(
    ctx.model,
    {
      systemPrompt: commitMessageSystemPrompt,
      messages: [{
        role: "user",
        content: [{ type: "text", text: context }],
        timestamp: Date.now(),
      }],
    },
    { apiKey: auth.apiKey, headers: auth.headers, env: auth.env },
  );
  if (response.stopReason !== "stop") {
    throw new Error(
      response.errorMessage
        || `当前模型没有完整生成提交信息（${response.stopReason}）`,
    );
  }
  const message = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("\n")
    .trim();
  if (!message) {
    throw new Error("当前模型生成了空提交信息");
  }
  return message;
}

function normalizeUserText(text) {
  const oldPrefix = "User request:\n";
  return text.startsWith(oldPrefix) ? text.slice(oldPrefix.length) : text;
}

function textContent(content) {
  if (typeof content === "string") {
    return content;
  }
  return content.map((block) => {
    if (block.type === "text") {
      return block.text;
    }
    if (block.type === "image") {
      return `[图片：${block.mimeType}]`;
    }
    throw new Error(`未知的消息内容类型: ${block.type}`);
  }).join("\n");
}

function assistantContent(content) {
  return content.map((block) => {
    if (block.type === "text") {
      return { type: "text", text: block.text };
    }
    if (block.type === "thinking") {
      return { type: "thinking", thinking: block.thinking };
    }
    if (block.type === "toolCall") {
      return {
        type: "toolCall",
        toolCallId: block.id,
        toolName: block.name,
        arguments: block.arguments,
      };
    }
    throw new Error(`未知的助手内容类型: ${block.type}`);
  });
}

function savedMessage(entry) {
  if (entry.type !== "message") {
    return undefined;
  }
  const message = entry.message;
  if (message.role === "user") {
    return {
      entryId: entry.id,
      role: "user",
      timestamp: message.timestamp,
      text: normalizeUserText(textContent(message.content)),
    };
  }
  if (message.role === "assistant") {
    return {
      entryId: entry.id,
      role: "assistant",
      timestamp: message.timestamp,
      content: assistantContent(message.content),
      provider: message.provider,
      model: message.model,
      usage: {
        input: message.usage.input,
        output: message.usage.output,
        cacheRead: message.usage.cacheRead,
        cacheWrite: message.usage.cacheWrite,
        cost: message.usage.cost.total,
      },
      stopReason: message.stopReason,
      errorMessage: message.errorMessage,
    };
  }
  if (message.role === "toolResult") {
    return {
      entryId: entry.id,
      role: "toolResult",
      timestamp: message.timestamp,
      text: textContent(message.content),
      toolCallId: message.toolCallId,
      toolName: message.toolName,
      isError: message.isError,
    };
  }
  if (message.role === "custom") {
    return {
      entryId: entry.id,
      role: "custom",
      timestamp: message.timestamp,
      customMessage: {
        customType: message.customType,
        content: message.content,
        display: message.display,
        details: message.details,
        timestamp: message.timestamp,
      },
    };
  }
  return undefined;
}

async function sessionSnapshot(ctx) {
  const activeSessionPath = ctx.sessionManager.getSessionFile();
  if (!activeSessionPath) {
    throw new Error("当前会话没有持久化文件");
  }
  const activeSessionId = ctx.sessionManager.getSessionId();
  const savedSessions = await SessionManager.listAll(ctx.sessionManager.getSessionDir());
  const savedActiveSession = savedSessions.find((session) => session.id === activeSessionId);
  if (savedActiveSession && savedActiveSession.path !== activeSessionPath) {
    throw new Error("当前会话路径与磁盘记录不一致");
  }
  let sessions = savedSessions;
  if (!savedActiveSession) {
    if (savedSessions.some((session) => session.path === activeSessionPath)) {
      throw new Error("当前会话与磁盘会话冲突");
    }
    const header = ctx.sessionManager.getHeader();
    if (!header || header.id !== activeSessionId || header.cwd !== ctx.cwd) {
      throw new Error("当前会话元数据无效");
    }
    const entries = ctx.sessionManager.getEntries();
    let firstMessage = "";
    let messageCount = 0;
    let modified = new Date(header.timestamp);
    for (const entry of entries) {
      if (entry.type !== "message") {
        continue;
      }
      messageCount += 1;
      const message = entry.message;
      if (message.role === "user" || message.role === "assistant") {
        modified = new Date(Math.max(modified.getTime(), message.timestamp));
      }
      if (!firstMessage && message.role === "user") {
        firstMessage = normalizeUserText(textContent(message.content));
      }
    }
    sessions = [{
      path: activeSessionPath,
      id: activeSessionId,
      cwd: ctx.cwd,
      name: ctx.sessionManager.getSessionName(),
      created: new Date(header.timestamp),
      modified,
      messageCount,
      firstMessage,
    }, ...savedSessions];
  }
  return {
    cwd: ctx.cwd,
    activeSessionPath,
    activeSessionId,
    sessions: sessions.map((session) => ({
      path: session.path,
      id: session.id,
      cwd: session.cwd,
      name: session.name,
      created: session.created.getTime(),
      modified: session.modified.getTime(),
      messageCount: session.messageCount,
      firstMessage: session.messageCount === 0 ? "" : normalizeUserText(session.firstMessage),
    })),
    messages: ctx.sessionManager.getBranch().map(savedMessage).filter((message) => message !== undefined),
  };
}

async function sendSessionSnapshot(ctx, kind) {
  notify(ctx, { kind, sessionSnapshot: await sessionSnapshot(ctx) });
}

// Bridges the Provider's typed login prompt to a native RPC dialog.
async function promptForAuth(ctx, prompt) {
  if (prompt.type === "select") {
    const ids = prompt.options.map((option) => option.id);
    const selected = await ctx.ui.select(
      `${prefix}${JSON.stringify({ kind: "authPrompt", prompt })}`,
      ids,
      { signal: prompt.signal },
    );
    if (selected === undefined) {
      throw new Error("登录已取消");
    }
    if (!ids.includes(selected)) {
      throw new Error("登录选项无效");
    }
    return selected;
  }

  const value = await ctx.ui.input(
    `${prefix}${JSON.stringify({ kind: "authPrompt", prompt })}`,
    prompt.placeholder,
    { signal: prompt.signal },
  );
  if (value === undefined || value.length === 0) {
    throw new Error("登录已取消");
  }
  return value;
}

// Reports Provider authentication state and currently available models from Pi.
function sendSnapshot(pi, ctx) {
  const allModels = ctx.modelRegistry.getAll();
  const providerIds = [...new Set(allModels.map((model) => model.provider))];
  const providers = providerIds
    .map((id) => {
      const provider = ctx.modelRegistry.getProvider(id);
      if (!provider) {
        throw new Error(`Provider 不存在: ${id}`);
      }
      return {
        id,
        name: provider.name,
        configured: ctx.modelRegistry.getProviderAuthStatus(id).configured,
        supportsAPIKeyLogin: typeof provider.auth.apiKey?.login === "function",
        supportsOAuthLogin: typeof provider.auth.oauth?.login === "function",
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
  const providerNames = new Map(providers.map((provider) => [provider.id, provider.name]));
  const models = ctx.modelRegistry
    .getAvailable()
    .map((model) => {
      const providerName = providerNames.get(model.provider);
      if (!providerName) {
        throw new Error(`Provider 名称不存在: ${model.provider}`);
      }
      return {
        id: model.id,
        name: model.name,
        providerId: model.provider,
        providerName,
        supportsImages: model.input.includes("image"),
        supportsReasoning: model.reasoning,
      };
    })
    .sort((left, right) => {
      const providerOrder = left.providerName.localeCompare(right.providerName);
      return providerOrder === 0 ? left.name.localeCompare(right.name) : providerOrder;
    });
  const commands = pi
    .getCommands()
    .filter((command) => !command.name.startsWith("quick-"))
    .map((command) => ({
      name: command.name,
      description: command.description,
      source: command.source,
    }));
  notify(ctx, { kind: "snapshot", snapshot: { providers, models, commands } });
}

// Registers app-owned Providers before Pi resolves models, then adds native control commands.
export default async function quickPiExtension(pi) {
  const dataDirectory = process.env.QUICK_PI_DATA_DIR;
  if (!dataDirectory) {
    throw new Error("QUICK_PI_DATA_DIR 未配置");
  }
  const modelDocument = JSON.parse(await readFile(join(dataDirectory, "models.json"), "utf8"));
  const credentials = await readCredentials(join(dataDirectory, "auth.json"));
  let providerIndex = 0;
  for (const [providerId, provider] of Object.entries(modelDocument.providers)) {
    const credential = credentials[providerId];
    if (credential?.type !== "api_key" || !credential.key) {
      throw new Error(`Provider 凭证无效: ${providerId}`);
    }
    const environmentName = `QUICK_PI_PROVIDER_KEY_${providerIndex}`;
    process.env[environmentName] = credential.key;
    pi.registerProvider(providerId, {
      ...provider,
      apiKey: `$${environmentName}`,
    });
    providerIndex += 1;
  }

  pi.registerCommand("quick-snapshot", {
    description: "Return Provider and model state to Quick Pi",
    handler: async (_args, ctx) => {
      sendSnapshot(pi, ctx);
    },
  });

  pi.registerCommand("quick-session-snapshot", {
    description: "Return session state to Quick Pi",
    handler: async (_args, ctx) => {
      await sendSessionSnapshot(ctx, "sessionSnapshot");
    },
  });

  pi.registerCommand("quick-generate-commit-message", {
    description: "Generate one Git commit message with the active model",
    handler: async (args, ctx) => {
      const request = decodeCommitMessageRequest(args);
      try {
        const message = await generateCommitMessage(ctx, request.context);
        notify(ctx, { kind: "commitMessage", requestId: request.requestId, message });
      } catch (error) {
        notify(ctx, {
          kind: "commitMessageError",
          requestId: request.requestId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    },
  });

  pi.registerCommand("quick-clone-turn", {
    description: "Clone one completed turn into a new Quick Pi session",
    handler: async (args, ctx) => {
      const entryId = args.trim();
      const branch = ctx.sessionManager.getBranch();
      const turnStartIndex = branch.findIndex((entry) => (
        entry.id === entryId
          && entry.type === "message"
          && entry.message.role === "user"
      ));
      if (turnStartIndex < 0) {
        throw new Error("克隆节点不属于当前会话分支");
      }

      let targetEntry = branch[turnStartIndex];
      let hasAssistantMessage = false;
      for (let index = turnStartIndex + 1; index < branch.length; index += 1) {
        const entry = branch[index];
        if (entry.type === "message" && entry.message.role === "user") {
          break;
        }
        targetEntry = entry;
        if (entry.type === "message" && entry.message.role === "assistant") {
          hasAssistantMessage = true;
        }
      }
      if (!hasAssistantMessage) {
        throw new Error("当前回复尚未持久化，不能克隆");
      }

      const result = await ctx.fork(targetEntry.id, {
        position: "at",
        withSession: async (nextCtx) => {
          await sendSessionSnapshot(nextCtx, "sessionCloned");
        },
      });
      if (result.cancelled) {
        throw new Error("插件取消了会话克隆");
      }
    },
  });

  pi.registerCommand("quick-delete-session", {
    description: "Delete one inactive Quick Pi session",
    handler: async (args, ctx) => {
      const sessionId = args.trim();
      if (!sessionId) {
        throw new Error("缺少要删除的会话 ID");
      }
      if (sessionId === ctx.sessionManager.getSessionId()) {
        throw new Error("不能删除当前活动会话");
      }
      const sessions = await SessionManager.listAll(ctx.sessionManager.getSessionDir());
      const target = sessions.find((session) => session.id === sessionId);
      if (!target) {
        throw new Error("要删除的会话不存在");
      }
      await unlink(target.path);
      await sendSessionSnapshot(ctx, "sessionDeleted");
    },
  });

  pi.registerCommand("quick-delete-all-sessions", {
    description: "Delete every saved Quick Pi session",
    handler: async (_args, ctx) => {
      const result = await ctx.newSession({
        withSession: async (nextCtx) => {
          const currentPath = nextCtx.sessionManager.getSessionFile();
          if (!currentPath) {
            throw new Error("新会话没有持久化文件");
          }
          const currentId = nextCtx.sessionManager.getSessionId();
          const sessions = await SessionManager.listAll(nextCtx.sessionManager.getSessionDir());
          for (const session of sessions) {
            if (session.id !== currentId) {
              await unlink(session.path);
            }
          }
          await sendSessionSnapshot(nextCtx, "sessionsDeleted");
        },
      });
      if (result.cancelled) {
        throw new Error("新建会话已取消");
      }
    },
  });

  pi.registerCommand("quick-login", {
    description: "Authenticate a Provider from Quick Pi",
    handler: async (args, ctx) => {
      const [providerId, authType] = args.trim().split(/\s+/u);
      if (!providerId || (authType !== "api_key" && authType !== "oauth")) {
        throw new Error("登录参数无效");
      }
      const provider = ctx.modelRegistry.getProvider(providerId);
      if (!provider) {
        throw new Error(`Provider 不存在: ${providerId}`);
      }
      const method = authType === "api_key" ? provider.auth.apiKey : provider.auth.oauth;
      if (!method?.login) {
        throw new Error(`${provider.name} 不支持所选登录方式`);
      }
      const credential = await method.login({
        prompt: (prompt) => promptForAuth(ctx, prompt),
        notify: (event) => notify(ctx, { kind: "authEvent", event }),
      });
      const directory = process.env.PI_CODING_AGENT_DIR;
      if (!directory) {
        throw new Error("PI_CODING_AGENT_DIR 未配置");
      }
      const credentials = await readCredentials(join(directory, "auth.json"));
      credentials[providerId] = credential;
      await writeCredentials(directory, credentials);
      notify(ctx, { kind: "authComplete", providerId });
    },
  });

  pi.registerCommand("quick-logout", {
    description: "Remove a Provider credential from Quick Pi",
    handler: async (providerId, ctx) => {
      const id = providerId.trim();
      if (!ctx.modelRegistry.getProvider(id)) {
        throw new Error(`Provider 不存在: ${id}`);
      }
      const directory = process.env.PI_CODING_AGENT_DIR;
      if (!directory) {
        throw new Error("PI_CODING_AGENT_DIR 未配置");
      }
      const credentials = await readCredentials(join(directory, "auth.json"));
      delete credentials[id];
      await writeCredentials(directory, credentials);
      notify(ctx, { kind: "logoutComplete", providerId: id });
    },
  });

  pi.registerCommand("reload", {
    description: "Reload extensions, skills, prompts, themes, and context files",
    handler: async (_args, ctx) => {
      await ctx.reload();
    },
  });
}
