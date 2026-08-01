import { Type } from "typebox";

const QuestionOptionSchema = Type.Object({
  value: Type.String({ description: "Value returned when selected" }),
  label: Type.String({ description: "Display label for the option" }),
  description: Type.Optional(Type.String({ description: "Optional explanation shown beside the label" })),
  recommended: Type.Optional(Type.Boolean({ description: "Whether this option is recommended" })),
});

const QuestionSchema = Type.Object({
  id: Type.String({ description: "Unique question identifier" }),
  label: Type.Optional(Type.String({ description: "Short progress label" })),
  prompt: Type.String({ description: "Full question text" }),
  options: Type.Array(QuestionOptionSchema),
  allowOther: Type.Optional(Type.Boolean({ description: "Allow a custom written answer" })),
});

const QuestionnaireParams = Type.Object({
  questions: Type.Array(QuestionSchema),
});

function errorResult(message, questions = []) {
  return {
    content: [{ type: "text", text: message }],
    details: { questions, answers: [], cancelled: true },
  };
}

function decodeResponse(value, questions) {
  if (!value) {
    return { questions, answers: [], cancelled: true };
  }
  const response = JSON.parse(value);
  if (response?.cancelled === true) {
    return { questions, answers: [], cancelled: true };
  }
  if (!Array.isArray(response?.answers)) {
    throw new Error("问卷响应缺少答案");
  }
  const questionIds = new Set(questions.map((question) => question.id));
  const seenIds = new Set();
  for (const answer of response.answers) {
    if (typeof answer?.id !== "string" || !questionIds.has(answer.id) || seenIds.has(answer.id)) {
      throw new Error("问卷答案 ID 无效");
    }
    if (typeof answer.value !== "string" || typeof answer.label !== "string") {
      throw new Error("问卷答案内容无效");
    }
    if (typeof answer.wasCustom !== "boolean") {
      throw new Error("问卷答案类型无效");
    }
    if (answer.index !== undefined && (!Number.isInteger(answer.index) || answer.index < 1)) {
      throw new Error("问卷选项序号无效");
    }
    seenIds.add(answer.id);
  }
  return { questions, answers: response.answers, cancelled: false };
}

export default function quickPiQuestionnaire(pi) {
  pi.registerTool({
    name: "questionnaire",
    label: "Questionnaire",
    description: "Ask one or more structured clarifying questions with options, descriptions, recommendations, and optional custom answers.",
    parameters: QuestionnaireParams,
    executionMode: "sequential",

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (ctx.mode !== "rpc" || !ctx.hasUI) {
        return errorResult("Error: Quick Pi questionnaire UI is available only in RPC mode");
      }
      if (params.questions.length === 0) {
        return errorResult("Error: No questions provided");
      }

      const questions = params.questions.map((question, index) => ({
        ...question,
        label: question.label || `Q${index + 1}`,
        allowOther: question.allowOther !== false,
      }));
      const title = `quickpi:${JSON.stringify({
        kind: "questionnaire",
        questionnaire: { questions },
      })}`;
      const value = await ctx.ui.input(title, "");
      const result = decodeResponse(value, questions);

      if (result.cancelled) {
        return {
          content: [{ type: "text", text: "User cancelled the questionnaire" }],
          details: result,
        };
      }
      if (result.answers.length === 0) {
        return {
          content: [{ type: "text", text: "User skipped all questionnaire questions" }],
          details: result,
        };
      }

      const answerLines = result.answers.map((answer) => {
        const question = questions.find((candidate) => candidate.id === answer.id);
        const questionLabel = question?.label || answer.id;
        if (answer.wasCustom) {
          return `${questionLabel}: user wrote: ${answer.label}`;
        }
        return `${questionLabel}: user selected: ${answer.index}. ${answer.label}`;
      });
      return {
        content: [{ type: "text", text: answerLines.join("\n") }],
        details: result,
      };
    },
  });
}
