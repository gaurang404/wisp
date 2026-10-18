import XCTest
@testable import Wisp

final class YAMLTests: XCTestCase {
    func testNestedMapsAndScalars() throws {
        let y = """
        # comment
        ---
        openapi: 3.0.1
        info:
          title: "Pet \\"Store\\"" # trailing comment
          version: '1.0'
          count: 42
          ratio: 1.5
          on: true
          nothing: ~
          url: http://example.com/a#b
          single: 'it''s'
          unicode: "caf\\u00e9 \\t!"
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        XCTAssertEqual(d["openapi"] as? String, "3.0.1")
        let info = try XCTUnwrap(d["info"] as? [String: Any])
        XCTAssertEqual(info["title"] as? String, "Pet \"Store\"")
        XCTAssertEqual(info["version"] as? String, "1.0")
        XCTAssertEqual(info["count"] as? Int, 42)
        XCTAssertEqual(info["ratio"] as? Double, 1.5)
        XCTAssertEqual(info["on"] as? Bool, true)
        XCTAssertTrue(info["nothing"] is NSNull)
        XCTAssertEqual(info["url"] as? String, "http://example.com/a#b")
        XCTAssertEqual(info["single"] as? String, "it's")
        XCTAssertEqual(info["unicode"] as? String, "café \t!")
    }

    func testSequencesOfMaps() throws {
        let y = """
        params:
        - name: id
          in: path
          required: true
        - name: q
          in: query
        tags:
          - a
          - b
        nested:
          - - 1
            - 2
          -
            k: v
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        let params = try XCTUnwrap(d["params"] as? [[String: Any]])
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0]["name"] as? String, "id")
        XCTAssertEqual(params[0]["required"] as? Bool, true)
        XCTAssertEqual(params[1]["in"] as? String, "query")
        XCTAssertEqual(d["tags"] as? [String], ["a", "b"])
        let nested = try XCTUnwrap(d["nested"] as? [Any])
        XCTAssertEqual(nested[0] as? [Int], [1, 2])
        XCTAssertEqual((nested[1] as? [String: Any])?["k"] as? String, "v")
    }

    func testBlockScalars() throws {
        let y = """
        lit: |
          line one
            indented
          line three

        folded: >-
          a b
          c

          d
        keep: |+
          x

        strip: |-
          y
        after: 1
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        XCTAssertEqual(d["lit"] as? String, "line one\n  indented\nline three\n")
        XCTAssertEqual(d["folded"] as? String, "a b c\nd")
        XCTAssertEqual(d["keep"] as? String, "x\n\n")
        XCTAssertEqual(d["strip"] as? String, "y")
        XCTAssertEqual(d["after"] as? Int, 1)
    }

    func testFlowCollections() throws {
        let y = """
        a: [1, two, "three", {x: 1, y: [true, null]}]
        b: {k: v, "q": 'w', empty: []}
        c: [
          multi,
          line
        ]
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        let a = try XCTUnwrap(d["a"] as? [Any])
        XCTAssertEqual(a[0] as? Int, 1)
        XCTAssertEqual(a[1] as? String, "two")
        XCTAssertEqual(a[2] as? String, "three")
        let inner = try XCTUnwrap(a[3] as? [String: Any])
        XCTAssertEqual(inner["x"] as? Int, 1)
        XCTAssertEqual((inner["y"] as? [Any])?.first as? Bool, true)
        let b = try XCTUnwrap(d["b"] as? [String: Any])
        XCTAssertEqual(b["k"] as? String, "v")
        XCTAssertEqual(b["q"] as? String, "w")
        XCTAssertEqual((b["empty"] as? [Any])?.count, 0)
        XCTAssertEqual(d["c"] as? [String], ["multi", "line"])
    }

    func testAnchorsAliasesAndMerge() throws {
        let y = """
        base: &base
          a: 1
          b: 2
        copy: *base
        merged:
          <<: *base
          b: 3
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        XCTAssertEqual((d["copy"] as? [String: Any])?["a"] as? Int, 1)
        let m = try XCTUnwrap(d["merged"] as? [String: Any])
        XCTAssertEqual(m["a"] as? Int, 1)
        XCTAssertEqual(m["b"] as? Int, 3)
    }

    func testJSONIsYAMLAndKeepsOrder() throws {
        let d = try XCTUnwrap(YAML.parse(#"{"z": 1, "a": {"y": "\/x😀"}, "m": [1.5e2, false]}"#, keepOrder: true) as? [String: Any])
        XCTAssertEqual(YAML.keys(d), ["z", "a", "m"])
        XCTAssertEqual((d["a"] as? [String: Any])?["y"] as? String, "/x😀")
        XCTAssertEqual((d["m"] as? [Any])?.first as? Double, 150)
    }

    func testMultilinePlainAndQuoted() throws {
        let y = """
        description: This is a long
          plain scalar
        quoted: "first
          second"
        """
        let d = try XCTUnwrap(YAML.parse(y) as? [String: Any])
        XCTAssertEqual(d["description"] as? String, "This is a long plain scalar")
        XCTAssertEqual(d["quoted"] as? String, "first second")
    }

    func testBadInputThrows() {
        XCTAssertThrowsError(try YAML.parse("a: [1, 2"))
        XCTAssertThrowsError(try YAML.parse("a: \"unterminated"))
        XCTAssertThrowsError(try YAML.parse("a: 1\n   b: 2"))
        XCTAssertThrowsError(try YAML.parse("a: *missing"))
        XCTAssertThrowsError(try YAML.parse("{a: 1}}"))
    }
}

final class ImporterTests: XCTestCase {
    static let petstoreYAML = """
    openapi: 3.0.3
    info:
      title: Petstore
      version: "1.0.0"
    servers:
      - url: https://{env}.petstore.io/v1
        variables:
          env:
            default: api
    security:
      - bearerAuth: []
    paths:
      /pets:
        get:
          summary: List pets
          tags: [pets]
          description: |
            Returns **all** pets.
            Paginated.
          parameters:
            - name: limit
              in: query
              required: true
              schema:
                type: integer
                example: 20
            - name: tag
              in: query
              description: Filter by tag
              schema:
                type: string
          responses:
            '200':
              description: A list of pets
            default:
              description: Error
        post:
          operationId: createPet
          tags: [pets]
          requestBody:
            required: true
            content:
              application/json:
                schema:
                  $ref: '#/components/schemas/NewPet'
          responses:
            '201': {description: Created}
      /pets/{petId}:
        parameters:
          - $ref: '#/components/parameters/PetId'
        get:
          tags: [pets]
          security:
            - apiKey: []
          responses:
            '200':
              description: OK
        delete:
          summary: Delete pet
          security:
            - oauth:
                - pets:write
                - pets:read
          responses:
            '204':
              description: Deleted
    components:
      parameters:
        PetId:
          name: petId
          in: path
          required: true
          schema: {type: string, format: uuid}
      securitySchemes:
        bearerAuth:
          type: http
          scheme: bearer
        apiKey:
          type: apiKey
          in: header
          name: X-API-Key
        oauth:
          type: oauth2
          flows:
            clientCredentials:
              tokenUrl: https://auth.petstore.io/token
              scopes: {}
            authorizationCode:
              authorizationUrl: https://auth.petstore.io/authorize
              tokenUrl: https://auth.petstore.io/token
              scopes: {}
      schemas:
        NewPet:
          type: object
          required: [name]
          properties:
            name:
              type: string
              example: Rex
            id:
              type: string
              readOnly: true
            born:
              type: string
              format: date-time
            owner:
              $ref: '#/components/schemas/Owner'
            tags:
              type: array
              items:
                type: string
                enum: [cute, loud]
            parent:
              $ref: '#/components/schemas/NewPet'
        Owner:
          allOf:
            - type: object
              properties:
                email: {type: string, format: email}
            - type: object
              properties:
                age: {type: integer}
    """

    func testOpenAPI3YAML() throws {
        let r = try Importer.parse(text: Self.petstoreYAML)
        XCTAssertEqual(r.format, "OpenAPI 3.0")
        XCTAssertEqual(r.name, "Petstore")
        XCTAssertEqual(r.requests.count, 4)
        XCTAssertEqual(r.variables.first?.key, "baseUrl")
        XCTAssertEqual(r.variables.first?.value, "https://api.petstore.io/v1")

        let list = r.requests[0]
        XCTAssertEqual(list.name, "List pets")
        XCTAssertEqual(list.method, .GET)
        XCTAssertEqual(list.folder, "Petstore/pets")
        XCTAssertEqual(list.url, "{{baseUrl}}/pets")
        XCTAssertEqual(list.params.map(\.key), ["limit", "tag"])
        XCTAssertEqual(list.params[0].enabled, true)
        XCTAssertEqual(list.params[0].value, "20")
        XCTAssertEqual(list.params[1].enabled, false)
        XCTAssertEqual(list.auth.kind, .bearer)
        XCTAssertEqual(list.auth.token, "{{token}}")
        XCTAssertTrue(list.docs.hasPrefix("# List pets"))
        XCTAssertTrue(list.docs.contains("Returns **all** pets.\nPaginated."))
        XCTAssertTrue(list.docs.contains("| `tag` | query | no | string | Filter by tag |"))
        XCTAssertTrue(list.docs.contains("- `200` — A list of pets"))

        let create = r.requests[1]
        XCTAssertEqual(create.name, "createPet")
        XCTAssertEqual(create.method, .POST)
        XCTAssertEqual(create.bodyKind, .json)
        XCTAssertTrue(create.docs.contains("`NewPet`"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(create.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Rex")
        XCTAssertNil(body["id"], "readOnly properties are skipped")
        XCTAssertEqual(body["born"] as? String, "2024-01-01T12:00:00Z")
        XCTAssertEqual(body["tags"] as? [String], ["cute"])
        let owner = try XCTUnwrap(body["owner"] as? [String: Any])
        XCTAssertEqual(owner["email"] as? String, "user@example.com")
        XCTAssertEqual(owner["age"] as? Int, 0)
        XCTAssertNotNil(body["parent"], "recursive ref is cut off, not infinite")
        // Key order follows the schema.
        XCTAssertTrue(create.body.range(of: "\"name\"")!.lowerBound < create.body.range(of: "\"born\"")!.lowerBound)

        let get = r.requests[2]
        XCTAssertEqual(get.name, "GET /pets/{petId}")
        XCTAssertEqual(get.url, "{{baseUrl}}/pets/{{petId}}")
        XCTAssertEqual(get.auth.kind, .apiKey)
        XCTAssertEqual(get.auth.apiKeyName, "X-API-Key")
        XCTAssertEqual(get.auth.apiKeyValue, "{{apiKey}}")
        XCTAssertTrue(get.docs.contains("| `petId` | path | yes | string (uuid) |"))

        let del = r.requests[3]
        XCTAssertEqual(del.folder, "Petstore")
        XCTAssertEqual(del.auth.kind, .oauth2)
        XCTAssertEqual(del.auth.oauth.grant, .authorizationCode)
        XCTAssertEqual(del.auth.oauth.authURL, "https://auth.petstore.io/authorize")
        XCTAssertEqual(del.auth.oauth.tokenURL, "https://auth.petstore.io/token")
        XCTAssertEqual(del.auth.oauth.scope, "pets:write pets:read")
        XCTAssertEqual(del.auth.oauth.clientID, "{{clientId}}")

        let keys = r.variables.map(\.key)
        for k in ["baseUrl", "petId", "token", "apiKey", "clientId", "clientSecret"] {
            XCTAssertTrue(keys.contains(k), "missing var \(k)")
        }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testOpenAPIFormBodyAndRelativeServer() throws {
        let y = """
        openapi: 3.1.0
        info: {title: Forms}
        servers: [{url: /api}]
        paths:
          /login:
            post:
              requestBody:
                content:
                  application/x-www-form-urlencoded:
                    schema:
                      type: object
                      properties:
                        user: {type: string}
                        remember: {type: boolean}
              responses: {}
        """
        let r = try Importer.parse(Data(y.utf8))
        XCTAssertEqual(r.format, "OpenAPI 3.1")
        XCTAssertEqual(r.variables.first?.value, "http://localhost/api")
        let req = r.requests[0]
        XCTAssertEqual(req.name, "POST /login")
        XCTAssertEqual(req.bodyKind, .form)
        XCTAssertEqual(req.form.map(\.key), ["user", "remember"])
        XCTAssertEqual(req.form.map(\.value), ["string", "true"])
    }

    func testSwagger2JSON() throws {
        let json = """
        {
          "swagger": "2.0",
          "info": {"title": "Legacy", "version": "1"},
          "host": "legacy.example.com",
          "basePath": "/v2",
          "schemes": ["https"],
          "securityDefinitions": {
            "basic": {"type": "basic"},
            "oauth": {"type": "oauth2", "flow": "application", "tokenUrl": "https://legacy.example.com/token", "scopes": {"read": "r"}}
          },
          "security": [{"basic": []}],
          "paths": {
            "/users/{id}": {
              "put": {
                "tags": ["users"],
                "summary": "Update user",
                "parameters": [
                  {"name": "id", "in": "path", "required": true, "type": "integer", "x-example": 7},
                  {"name": "X-Trace", "in": "header", "type": "string"},
                  {"name": "body", "in": "body", "schema": {"$ref": "#/definitions/User"}}
                ],
                "responses": {"200": {"description": "ok"}}
              }
            },
            "/token": {
              "post": {
                "security": [{"oauth": ["read"]}],
                "consumes": ["application/x-www-form-urlencoded"],
                "parameters": [
                  {"name": "grant", "in": "formData", "type": "string", "default": "client_credentials"},
                  {"name": "file", "in": "formData", "type": "file"}
                ],
                "responses": {}
              }
            }
          },
          "definitions": {
            "User": {"type": "object", "properties": {"name": {"type": "string"}, "id": {"type": "string", "format": "uuid"}}}
          }
        }
        """
        let r = try Importer.parse(Data(json.utf8))
        XCTAssertEqual(r.format, "Swagger 2.0")
        XCTAssertEqual(r.variables.first?.value, "https://legacy.example.com/v2")
        let put = r.requests[0]
        XCTAssertEqual(put.folder, "Legacy/users")
        XCTAssertEqual(put.method, .PUT)
        XCTAssertEqual(put.url, "{{baseUrl}}/users/{{id}}")
        XCTAssertEqual(r.variables.first { $0.key == "id" }?.value, "7")
        XCTAssertEqual(put.headers.first?.key, "X-Trace")
        XCTAssertEqual(put.headers.first?.enabled, false)
        XCTAssertEqual(put.bodyKind, .json)
        XCTAssertEqual(put.body, "{\n  \"name\": \"string\",\n  \"id\": \"3fa85f64-5717-4562-b3fc-2c963f66afa6\"\n}")
        XCTAssertEqual(put.auth.kind, .basic)
        XCTAssertEqual(put.auth.username, "{{username}}")

        let tok = r.requests[1]
        XCTAssertEqual(tok.bodyKind, .form)
        XCTAssertEqual(tok.form.map(\.key), ["grant"])
        XCTAssertEqual(tok.form.first?.value, "client_credentials")
        XCTAssertEqual(tok.auth.kind, .oauth2)
        XCTAssertEqual(tok.auth.oauth.grant, .clientCredentials)
        XCTAssertEqual(tok.auth.oauth.scope, "read")
    }

    func testPostmanCollection() throws {
        let json = """
        {
          "info": {"name": "Shop", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
          "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}", "type": "string"}]},
          "variable": [{"key": "host", "value": "https://shop.io"}],
          "item": [
            {
              "name": "Orders",
              "item": [
                {
                  "name": "Admin",
                  "auth": {"type": "basic", "basic": [{"key": "username", "value": "admin"}, {"key": "password", "value": "pw"}]},
                  "item": [
                    {"name": "Refund", "request": {
                      "method": "POST",
                      "url": {"raw": "{{host}}/orders/:orderId/refund", "variable": [{"key": "orderId", "value": "42"}]},
                      "header": [{"key": "X-Off", "value": "1", "disabled": true}],
                      "body": {"mode": "urlencoded", "urlencoded": [{"key": "amount", "value": "10"}, {"key": "note", "value": "x", "disabled": true}]}
                    }}
                  ]
                },
                {"name": "List orders", "request": {
                  "method": "GET", "url": "{{host}}/orders?page=1",
                  "description": "Lists orders."
                }},
                {"name": "Create", "request": {
                  "method": "POST", "url": {"raw": "{{host}}/orders"},
                  "auth": {"type": "noauth"},
                  "body": {"mode": "raw", "raw": "{\\"sku\\":\\"A1\\",\\"qty\\":{{qty}}}", "options": {"raw": {"language": "json"}}}
                }},
                {"name": "GQL", "request": {
                  "method": "POST", "url": "{{host}}/graphql",
                  "body": {"mode": "graphql", "graphql": {"query": "{ me { id } }", "variables": "{\\"a\\": 1}"}}
                }}
              ]
            }
          ]
        }
        """
        let r = try Importer.parse(Data(json.utf8))
        XCTAssertEqual(r.format, "Postman v2.1")
        XCTAssertEqual(r.name, "Shop")
        XCTAssertEqual(r.requests.count, 4)
        XCTAssertTrue(r.variables.contains { $0.key == "host" && $0.value == "https://shop.io" })
        XCTAssertTrue(r.variables.contains { $0.key == "orderId" && $0.value == "42" })

        let refund = r.requests[0]
        XCTAssertEqual(refund.folder, "Shop/Orders/Admin")
        XCTAssertEqual(refund.url, "{{host}}/orders/{{orderId}}/refund")
        XCTAssertEqual(refund.auth.kind, .basic)
        XCTAssertEqual(refund.auth.username, "admin")
        XCTAssertEqual(refund.headers.first?.enabled, false)
        XCTAssertEqual(refund.bodyKind, .form)
        XCTAssertEqual(refund.form.map(\.key), ["amount", "note"])
        XCTAssertEqual(refund.form.map(\.enabled), [true, false])

        let list = r.requests[1]
        XCTAssertEqual(list.folder, "Shop/Orders")
        XCTAssertEqual(list.auth.kind, .bearer, "collection auth is inherited")
        XCTAssertEqual(list.auth.token, "{{token}}")
        XCTAssertTrue(list.docs.contains("Lists orders."))

        let create = r.requests[2]
        XCTAssertEqual(create.auth.kind, .none)
        XCTAssertEqual(create.bodyKind, .json)
        XCTAssertEqual(create.body, "{\"sku\":\"A1\",\"qty\":{{qty}}}", "non-JSON templated bodies are kept verbatim")

        let gql = r.requests[3]
        XCTAssertEqual(gql.bodyKind, .json)
        XCTAssertEqual(gql.body, "{\n  \"query\": \"{ me { id } }\",\n  \"variables\": {\n    \"a\": 1\n  }\n}")
    }

    func testInsomnia() throws {
        let json = """
        {"_type": "export", "__export_format": 4, "resources": [
          {"_id": "wrk_1", "_type": "workspace", "name": "My API"},
          {"_id": "env_1", "_type": "environment", "parentId": "wrk_1", "data": {"base": "https://x.io", "token": ""}},
          {"_id": "env_2", "_type": "environment", "parentId": "env_1", "data": {"token": "abc"}},
          {"_id": "fld_1", "_type": "request_group", "parentId": "wrk_1", "name": "Users"},
          {"_id": "fld_2", "_type": "request_group", "parentId": "fld_1", "name": "Admin"},
          {"_id": "req_1", "_type": "request", "parentId": "fld_2", "name": "Create user", "method": "POST",
           "url": "{{ _.base }}/users", "description": "Makes a user",
           "body": {"mimeType": "application/json", "text": "{\\"name\\":\\"a\\"}"},
           "headers": [{"name": "Content-Type", "value": "application/json"}],
           "parameters": [{"name": "dry", "value": "1", "disabled": true}],
           "authentication": {"type": "bearer", "token": "{{ _.token }}"}},
          {"_id": "req_2", "_type": "request", "parentId": "wrk_1", "name": "Login", "method": "POST", "url": "{{_.base}}/login",
           "body": {"mimeType": "application/x-www-form-urlencoded", "params": [{"name": "u", "value": "me"}]}}
        ]}
        """
        let r = try Importer.parse(Data(json.utf8))
        XCTAssertEqual(r.format, "Insomnia")
        XCTAssertEqual(r.name, "My API")
        XCTAssertEqual(r.variables.map(\.key), ["base", "token"])
        XCTAssertEqual(r.variables.map(\.value), ["https://x.io", "abc"])
        let c = r.requests[0]
        XCTAssertEqual(c.folder, "My API/Users/Admin")
        XCTAssertEqual(c.url, "{{base}}/users")
        XCTAssertEqual(c.auth.kind, .bearer)
        XCTAssertEqual(c.auth.token, "{{token}}")
        XCTAssertEqual(c.bodyKind, .json)
        XCTAssertEqual(c.body, "{\n  \"name\": \"a\"\n}")
        XCTAssertEqual(c.params.first?.enabled, false)
        XCTAssertTrue(c.docs.contains("Makes a user"))
        let l = r.requests[1]
        XCTAssertEqual(l.folder, "My API")
        XCTAssertEqual(l.url, "{{base}}/login")
        XCTAssertEqual(l.bodyKind, .form)
        XCTAssertEqual(l.form.first?.value, "me")
    }

    func testHAR() throws {
        let json = """
        {"log": {"version": "1.2", "entries": [
          {"request": {"method": "POST", "url": "https://api.site.com/v1/items?x=1",
            "headers": [{"name": ":authority", "value": "api.site.com"}, {"name": "Cookie", "value": "a=b"},
                        {"name": "Content-Length", "value": "9"}, {"name": "Authorization", "value": "Bearer t"},
                        {"name": "Content-Type", "value": "application/json"}],
            "postData": {"mimeType": "application/json", "text": "{\\"a\\":1}"}},
           "response": {"status": 200, "content": {"mimeType": "application/json"}}},
          {"request": {"method": "GET", "url": "https://cdn.site.com/logo.png", "headers": []}, "response": {"content": {"mimeType": "image/png"}}},
          {"request": {"method": "GET", "url": "https://site.com/app", "headers": []}, "response": {"content": {"mimeType": "application/javascript"}}},
          {"request": {"method": "POST", "url": "https://site.com/form", "headers": [],
            "postData": {"mimeType": "application/x-www-form-urlencoded", "text": "q=hello+world&n=2"}}, "response": {}}
        ]}}
        """
        let r = try Importer.parse(Data(json.utf8))
        XCTAssertEqual(r.format, "HAR")
        XCTAssertEqual(r.requests.count, 2)
        let a = r.requests[0]
        XCTAssertEqual(a.folder, "api.site.com")
        XCTAssertEqual(a.name, "POST /v1/items")
        XCTAssertEqual(a.headers.map(\.key), ["Authorization", "Content-Type"])
        XCTAssertEqual(a.bodyKind, .json)
        XCTAssertEqual(a.body, "{\n  \"a\": 1\n}")
        let f = r.requests[1]
        XCTAssertEqual(f.bodyKind, .form)
        XCTAssertEqual(f.form.map(\.value), ["hello world", "2"])
    }

    func testMultipleCurls() throws {
        let text = """
        # exported
        curl https://a.example.com/one -H 'X-A: 1'

        curl -X POST https://b.example.com/two \\
          -H 'Content-Type: application/json' \\
          -d '{"k":1}'
        """
        let r = try Importer.parse(text: text)
        XCTAssertEqual(r.format, "cURL")
        XCTAssertEqual(r.requests.count, 2)
        XCTAssertEqual(r.requests[0].url, "https://a.example.com/one")
        XCTAssertEqual(r.requests[0].folder, "a.example.com")
        XCTAssertEqual(r.requests[1].method, .POST)
        XCTAssertEqual(r.requests[1].bodyKind, .json)
        XCTAssertEqual(r.requests[1].name, "POST /two")
    }

    func testUnrecognizedAndInvalid() {
        XCTAssertThrowsError(try Importer.parse(text: "{\"hello\": 1}")) { e in
            guard case ImportError.unrecognized = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try Importer.parse(text: "just: [broken"))
        XCTAssertThrowsError(try Importer.parse(text: ""))
        XCTAssertThrowsError(try Importer.parse(Data([0xFF, 0xFE, 0x00])))
        XCTAssertNotNil(ImportError.unrecognized.errorDescription)
    }
}
