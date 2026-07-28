import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

const prefix = "quickpi:";

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
function sendSnapshot(ctx) {
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
      };
    })
    .sort((left, right) => {
      const providerOrder = left.providerName.localeCompare(right.providerName);
      return providerOrder === 0 ? left.name.localeCompare(right.name) : providerOrder;
    });
  notify(ctx, { kind: "snapshot", snapshot: { providers, models } });
}

// Registers the three native-app commands used for snapshots and built-in Provider login state.
export default function quickPiExtension(pi) {
  pi.registerCommand("quick-snapshot", {
    description: "Return Provider and model state to Quick Pi",
    handler: async (_args, ctx) => {
      sendSnapshot(ctx);
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
}
