export interface OllamaChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface OllamaChatRequest {
  model: string;
  messages: OllamaChatMessage[];
}

interface OllamaChatResponse {
  message?: {
    role?: string;
    content?: string;
  };
}

export class OllamaClient {
  constructor(private readonly baseUrl: string) {}

  async chat(request: OllamaChatRequest): Promise<string> {
    const response = await fetch(`${this.baseUrl}/api/chat`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: request.model,
        messages: request.messages,
        stream: false,
      }),
    });

    if (!response.ok) {
      throw new Error(`Ollama chat failed with ${response.status}`);
    }

    const json = (await response.json()) as OllamaChatResponse;
    const text = json.message?.content?.trim();
    if (!text) {
      throw new Error("Ollama returned empty content.");
    }
    return text;
  }

  async isReachable(model: string): Promise<boolean> {
    try {
      await this.chat({
        model,
        messages: [{ role: "user", content: "Reply with: ok" }],
      });
      return true;
    } catch {
      return false;
    }
  }
}
