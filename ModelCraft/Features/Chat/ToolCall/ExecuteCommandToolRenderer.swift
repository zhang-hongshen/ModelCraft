//
//  ExecuteCommandToolRenderer.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import MLXLMCommon

struct ExecuteCommandToolRenderer: View {

    let toolCall: ToolCall
    let result: CallToolResult?
    let status: ToolCallStatus

    @State private var isDetailPresented = false

    private var command: String {
        toolCall.function.arguments["command"]?.stringValue ?? "Unknown Command"
    }

    private var output: String? {

        guard let result, case let .text(text)? = result.content.first else {
            return nil
        }
        return text.text
    }
    
    var body: some View {
        Button {
            isDetailPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolCall.icon)
                if status == .running {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(toolCall.compactDescription(status))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isDetailPresented, arrowEdge: .leading) {
            TerminalView(
                command: command,
                output: output
            )
            .frame(width: 520)
            .padding(12)
        }
    }
}

struct TerminalView: View {
    let command: String
    let output: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.7)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.7)).frame(width: 10, height: 10)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    Text(">")
                        .foregroundStyle(Color.accentColor)
                        .bold()
                    Text(command)
                }
                
                if let output = output, !output.isEmpty {
                    ScrollView {
                        Text(output)
                            .foregroundStyle(.secondary)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                }
            }
            .font(.system(.subheadline, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            
        }
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .shadow(radius: 2)
    }
}

#Preview {
    ScrollView {
        let toolCall = ToolCall(function: .init(name: ToolNames.executeCommand, arguments: ["command": "ls -la"]))
        
        VStack {
            ExecuteCommandToolRenderer(toolCall: toolCall, result: nil, status: .running)
            
            let result = CallToolResult(content: [.text(TextContent(text: "total 0\ndrwxr-xr-x  2 user  staff   64 Sep  3 2026 ."))])
            ExecuteCommandToolRenderer(toolCall: toolCall, result: result, status: .completed)
            
            ExecuteCommandToolRenderer(toolCall: toolCall, result: nil, status: .failed)
        }
        .padding()
        
    }
}
