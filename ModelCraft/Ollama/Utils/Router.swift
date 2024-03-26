//
//  Router.swift
//
//
//  Created by Kevin Hermawan on 10/11/23.
//

import Foundation
import Alamofire

internal enum Router {
    static var baseURL = URL(string: "http://localhost:11434")!
    
    case root
    case models
    case modelInfo(data: ModelInfoRequest)
    case generate(data: GenerateRequest)
    case chat(data: ChatRequest)
    case copyModel(data: CopyModelRequest)
    case deleteModel(data: DeleteModelRequest)
    case pullModel(data: PullModelRequest)
    case generateEmbeddings(data: GenerateEmbeddingsRequest)
    case libraryModels
    
    internal var path: String {
        switch self {
        case .root: "/"
        case .models: "/api/tags"
        case .modelInfo: "/api/show"
        case .generate: "/api/generate"
        case .chat: "/api/chat"
        case .copyModel: "/api/copy"
        case .deleteModel: "/api/delete"
        case .generateEmbeddings: "/api/embeddings"
        case .pullModel: "/api/pull"
        case .libraryModels: "/library"
        }
    }
    
    internal var method: HTTPMethod {
        switch self {
        case .root: .head
        case .models: .get
        case .modelInfo: .post
        case .generate: .post
        case .chat: .post
        case .copyModel: .post
        case .deleteModel: .delete
        case .generateEmbeddings: .post
        case .pullModel: .post
        case .libraryModels: .get
        }
    }
    
    internal var headers: HTTPHeaders {
        ["Content-Type": "application/json"]
    }
    
    internal var url: URL {
        switch self {
        case .libraryModels: URL(string: "https://ollama.com")!.appendingPathComponent(path)
        default: Router.baseURL.appendingPathComponent(path)
        }
    }
}

extension Router: URLRequestConvertible {
    func asURLRequest() throws -> URLRequest {
        var request = URLRequest(url: url)
        request.method = method
        request.headers = headers
        
        switch self {
        case .modelInfo(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .generate(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .chat(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .copyModel(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .deleteModel(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .generateEmbeddings(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        case .pullModel(let data):
            request.httpBody = try JSONEncoder.default.encode(data)
        default:
            break
        }
        
        return request
    }
}
