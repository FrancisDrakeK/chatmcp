import 'package:dio/dio.dart';
import 'base_llm_client.dart';
import 'dart:convert';
import 'model.dart';
import 'package:logging/logging.dart';

var models = [
  Model(
    name: 'gpt-4o-mini',
    label: 'GPT-4o-mini',
  ),
  Model(
    name: 'gpt-4o',
    label: 'GPT-4o',
  ),
  Model(
    name: 'gpt-3.5-turbo',
    label: 'GPT-3.5',
  ),
  Model(
    name: 'gpt-4',
    label: 'GPT-4',
  ),
];

class OpenAIClient extends BaseLLMClient {
  final String apiKey;
  final String baseUrl;
  final String deepseekApiKey;
  final String deepseekBaseUrl;
  final Dio _dio;

  OpenAIClient({
    required this.apiKey,
    String? baseUrl,
    required this.deepseekApiKey,
    String? deepseekBaseUrl,
    Dio? dio,
  })  : baseUrl = (baseUrl == null || baseUrl.isEmpty)
            ? 'https://api.openai.com/v1'
            : baseUrl,
        deepseekBaseUrl = (deepseekBaseUrl == null || deepseekBaseUrl.isEmpty)
            ? 'https://api.deepseek.com/v1'
            : deepseekBaseUrl,
        _dio = dio ??
            Dio(BaseOptions(
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
            ));

  @override
  Future<LLMResponse> chatCompletion(CompletionRequest request) async {
    final body = {
      'model': request.model,
      'messages': request.messages.map((m) => m.toJson()).toList(),
    };

    if (request.tools != null && request.tools!.isNotEmpty) {
      body['tools'] = request.tools!;
      body['tool_choice'] = 'auto';
    }

    final bodyStr = jsonEncode(body);

    try {
      final String url;
      final String authorization;
      if (request.model.startsWith('deepseek')) {
        url = "$deepseekBaseUrl/chat/completions";
        authorization = 'Bearer $deepseekApiKey';
      } else {
        url = "$baseUrl/chat/completions";
        authorization = 'Bearer $apiKey';
      }

      final response = await _dio.post(
        url,
        options: Options(headers: {'Authorization': authorization}),
        data: bodyStr,
      );

      // 处理 ResponseBody 类型的响应
      var jsonData;
      if (response.data is ResponseBody) {
        final responseBody = response.data as ResponseBody;
        final responseStr = await utf8.decodeStream(responseBody.stream);
        jsonData = jsonDecode(responseStr);
      } else {
        jsonData = response.data;
      }

      final message = jsonData['choices'][0]['message'];

      // 解析工具调用
      final toolCalls = message['tool_calls']
          ?.map<ToolCall>((t) => ToolCall(
                id: t['id'],
                type: t['type'],
                function: FunctionCall(
                  name: t['function']['name'],
                  arguments: t['function']['arguments'],
                ),
              ))
          ?.toList();

      return LLMResponse(
        content: message['content'],
        toolCalls: toolCalls,
      );
    } catch (e) {
      final tips =
          "call chatCompletion failed: endpoint: $baseUrl/chat/completions body: $body $e";
      throw Exception(tips);
    }
  }

  @override
  Stream<LLMResponse> chatStreamCompletion(CompletionRequest request) async* {
    final body = {
      'model': request.model,
      'messages': request.messages.map((m) => m.toJson()).toList(),
      'stream': true,
    };

    try {
      _dio.options.responseType = ResponseType.stream;
      final String url;
      final String authorization;
      if (request.model.startsWith('deepseek')) {
        url = "$deepseekBaseUrl/chat/completions";
        authorization = 'Bearer $deepseekApiKey';
      } else {
        url = "$baseUrl/chat/completions";
        authorization = 'Bearer $apiKey';
      }

      final response = await _dio.post(
        url,
        options: Options(headers: {'Authorization': authorization}),
        data: jsonEncode(body),
      );

      String buffer = '';
      await for (final chunk in response.data.stream) {
        final decodedChunk = utf8.decode(chunk);
        buffer += decodedChunk;

        // 处理可能的多行数据
        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');
          final line = buffer.substring(0, index).trim();
          buffer = buffer.substring(index + 1);

          if (line.startsWith('data: ')) {
            final jsonStr = line.substring(6).trim();
            if (jsonStr.isEmpty || jsonStr == '[DONE]') continue;

            try {
              final json = jsonDecode(jsonStr);

              // 检查 choices 数组是否为空
              if (json['choices'] == null || json['choices'].isEmpty) {
                continue;
              }

              final delta = json['choices'][0]['delta'];
              if (delta == null) continue;

              // 解析工具调用
              final toolCalls = delta['tool_calls']
                  ?.map<ToolCall>((t) => ToolCall(
                        id: t['id'] ?? '',
                        type: t['type'] ?? '',
                        function: FunctionCall(
                          name: t['function']?['name'] ?? '',
                          arguments: t['function']?['arguments'] ?? '{}',
                        ),
                      ))
                  ?.toList();

              // 只在有内容或工具调用时才yield响应
              if (delta['content'] != null || toolCalls != null) {
                yield LLMResponse(
                  content: delta['content'],
                  toolCalls: toolCalls,
                );
              }
            } catch (e) {
              Logger.root.severe('Failed to parse chunk: $jsonStr $e');
              continue;
            }
          }
        }
      }
    } catch (e) {
      throw Exception(
          "call chatStreamCompletion failed: endpoint: $baseUrl/chat/completions body: $body $e");
    }
  }

  @override
  Future<String> genTitle(List<ChatMessage> messages) async {
    final conversationText = messages.map((msg) {
      final role = msg.role == MessageRole.user ? "Human" : "Assistant";
      return "$role: ${msg.content}";
    }).join("\n");

    final prompt = ChatMessage(
      role: MessageRole.assistant,
      content:
          """You are a conversation title generator. Generate a concise title (max 20 characters) for the following conversation.
The title should summarize the main topic. Return only the title without any explanation or extra punctuation.

Conversation:
$conversationText""",
    );

    final response = await chatCompletion(CompletionRequest(
      model: "gpt-4o-mini",
      messages: [prompt],
    ));
    return response.content?.trim() ?? "New Chat";
  }

  @override
  Future<List<String>> models() async {
    try {
      final openaiResponse = await _dio.get("$baseUrl/models");
      final deepseekResponse = await _dio.get("$deepseekBaseUrl/models");

      final openaiModels = (openaiResponse.data['data'] as List)
          .map((m) => m['id'].toString())
          .where((id) => id.contains('gpt') || id.contains('o1'))
          .toList();

      final deepseekModels = (deepseekResponse.data['data'] as List)
          .map((m) => m['id'].toString())
          .where((id) => id.contains('deepseek'))
          .toList();

      return [...openaiModels, ...deepseekModels];
    } catch (e, trace) {
      Logger.root.severe('获取模型列表失败: $e, trace: $trace');
      // 返回预定义的模型列表作为后备
      return [];
    }
  }
}
