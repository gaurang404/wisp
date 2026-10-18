import XCTest
@testable import Wisp

final class GraphQLTests: XCTestCase {
    // Compact hand-written introspection response (shape matches what real servers return).
    static let fixture = #"""
    {"data":{"__schema":{
      "queryType":{"name":"Query"},"mutationType":{"name":"Mutation"},"subscriptionType":null,
      "types":[
        {"kind":"OBJECT","name":"Query","description":null,"fields":[
          {"name":"search","description":null,"args":[{"name":"term","description":null,"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"defaultValue":null}],
           "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"UNION","name":"SearchResult","ofType":null}}}},"isDeprecated":false,"deprecationReason":null},
          {"name":"countries","description":"All countries","args":[
             {"name":"filter","description":null,"type":{"kind":"INPUT_OBJECT","name":"CountryFilterInput","ofType":null},"defaultValue":null},
             {"name":"first","description":null,"type":{"kind":"SCALAR","name":"Int","ofType":null},"defaultValue":"10"},
             {"name":"sort","description":null,"type":{"kind":"ENUM","name":"Sort","ofType":null},"defaultValue":null},
             {"name":"withEmoji","description":null,"type":{"kind":"SCALAR","name":"Boolean","ofType":null},"defaultValue":null},
             {"name":"codes","description":null,"type":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}}},"defaultValue":null}],
           "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"Country","ofType":null}}}},"isDeprecated":false,"deprecationReason":null},
          {"name":"country","description":null,"args":[{"name":"code","description":null,"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"defaultValue":null}],
           "type":{"kind":"OBJECT","name":"Country","ofType":null},"isDeprecated":false,"deprecationReason":null},
          {"name":"version","description":null,"args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false,"deprecationReason":null}
        ],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null},
        {"kind":"OBJECT","name":"Mutation","description":null,"fields":[
          {"name":"createUser","description":null,"args":[{"name":"input","description":null,"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"INPUT_OBJECT","name":"CreateUserInput","ofType":null}},"defaultValue":null}],
           "type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"User","ofType":null}},"isDeprecated":false,"deprecationReason":null}
        ],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null},
        {"kind":"OBJECT","name":"Country","description":null,"fields":[
          {"name":"code","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"isDeprecated":false},
          {"name":"name","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"isDeprecated":false},
          {"name":"emoji","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false},
          {"name":"capital","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false},
          {"name":"phone","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":true},
          {"name":"localName","args":[{"name":"lang","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"defaultValue":null}],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false},
          {"name":"languages","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"Language","ofType":null}}}},"isDeprecated":false},
          {"name":"continent","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"OBJECT","name":"Continent","ofType":null}},"isDeprecated":false}
        ],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null},
        {"kind":"OBJECT","name":"Language","fields":[
          {"name":"code","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"isDeprecated":false},
          {"name":"name","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false}]},
        {"kind":"OBJECT","name":"Continent","fields":[
          {"name":"code","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"isDeprecated":false},
          {"name":"name","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"isDeprecated":false}]},
        {"kind":"OBJECT","name":"User","fields":[
          {"name":"id","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"ID","ofType":null}},"isDeprecated":false},
          {"name":"email","args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"isDeprecated":false},
          {"name":"name","args":[],"type":{"kind":"SCALAR","name":"String","ofType":null},"isDeprecated":false},
          {"name":"country","args":[],"type":{"kind":"OBJECT","name":"Country","ofType":null},"isDeprecated":false}]},
        {"kind":"OBJECT","name":"Wrapper","fields":[
          {"name":"user","args":[],"type":{"kind":"OBJECT","name":"User","ofType":null},"isDeprecated":false}]},
        {"kind":"UNION","name":"SearchResult","fields":null,"possibleTypes":[{"kind":"OBJECT","name":"Country","ofType":null},{"kind":"OBJECT","name":"User","ofType":null}]},
        {"kind":"ENUM","name":"Sort","enumValues":[{"name":"ASC","isDeprecated":false},{"name":"DESC","isDeprecated":false}]},
        {"kind":"INPUT_OBJECT","name":"CountryFilterInput","inputFields":[
          {"name":"code","type":{"kind":"INPUT_OBJECT","name":"StringQueryOperatorInput","ofType":null},"defaultValue":null},
          {"name":"continent","type":{"kind":"INPUT_OBJECT","name":"StringQueryOperatorInput","ofType":null},"defaultValue":null}]},
        {"kind":"INPUT_OBJECT","name":"StringQueryOperatorInput","inputFields":[
          {"name":"eq","type":{"kind":"SCALAR","name":"String","ofType":null},"defaultValue":null},
          {"name":"in","type":{"kind":"LIST","name":null,"ofType":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}}},"defaultValue":null}]},
        {"kind":"INPUT_OBJECT","name":"CreateUserInput","inputFields":[
          {"name":"email","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"defaultValue":null},
          {"name":"age","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"Int","ofType":null}},"defaultValue":null},
          {"name":"nickname","type":{"kind":"SCALAR","name":"String","ofType":null},"defaultValue":null}]},
        {"kind":"SCALAR","name":"ID"},{"kind":"SCALAR","name":"String"},{"kind":"SCALAR","name":"Int"},
        {"kind":"SCALAR","name":"Float"},{"kind":"SCALAR","name":"Boolean"},
        {"kind":"OBJECT","name":"__Schema","fields":[]},{"kind":"OBJECT","name":"__Type","fields":[]}
      ]}}}
    """#

    var schema: GQLSchema!
    override func setUpWithError() throws {
        schema = try GraphQL.parseSchema(Data(Self.fixture.utf8))
    }
    func field(_ name: String, _ op: GQLOperation = .query) throws -> GQLField {
        try XCTUnwrap(schema.rootFields(op).first { $0.name == name })
    }
    func vars(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    // MARK: Schema

    func testParseSchemaAndRootFields() throws {
        XCTAssertEqual(schema.queryType, "Query")
        XCTAssertEqual(schema.mutationType, "Mutation")
        XCTAssertEqual(schema.rootFields(.query).map(\.name), ["countries", "country", "search", "version"])
        XCTAssertEqual(schema.rootFields(.mutation).map(\.name), ["createUser"])
        XCTAssertEqual(schema.typeCount, 17)
        XCTAssertEqual(schema.type("Sort")?.enumValues, ["ASC", "DESC"])
        XCTAssertEqual(schema.type("SearchResult")?.possibleTypes, ["Country", "User"])
        XCTAssertEqual(try field("countries").description, "All countries")
        XCTAssertEqual(try field("countries").args.first { $0.name == "first" }?.defaultValue, "10")
        XCTAssertTrue(schema.isLeaf(.nonNull(.named("ID"))))
        XCTAssertTrue(schema.isLeaf(.named("Sort")))
        XCTAssertFalse(schema.isLeaf(.named("Country")))
        XCTAssertEqual(schema.fields(of: try field("countries").type).count, 8)
        XCTAssertTrue(schema.fields(of: .named("SearchResult")).isEmpty)

        let noMutation = GQLSchema(queryType: "Query", mutationType: nil, types: schema.types)
        XCTAssertTrue(noMutation.rootFields(.mutation).isEmpty)
        XCTAssertEqual(GQLOperation.mutation.keyword, "mutation")
    }

    func testTypeRefDisplay() throws {
        let t = try field("countries").type
        XCTAssertEqual(t.display, "[Country!]!")
        XCTAssertEqual(t.name, "Country")
        XCTAssertTrue(t.isNonNull)
        XCTAssertTrue(t.isList)
        let c = try field("country").type
        XCTAssertEqual(c.display, "Country")
        XCTAssertFalse(c.isNonNull)
        XCTAssertFalse(c.isList)
        XCTAssertEqual(try field("country").args[0].type.display, "ID!")
    }

    func testParseSchemaErrors() {
        let disabled = Data(#"{"errors":[{"message":"introspection disabled"}]}"#.utf8)
        XCTAssertThrowsError(try GraphQL.parseSchema(disabled)) { err in
            XCTAssertEqual(err.localizedDescription, "Introspection is disabled on this server: introspection disabled")
        }
        XCTAssertThrowsError(try GraphQL.parseSchema(Data("<html>nope</html>".utf8))) { err in
            XCTAssertTrue(err.localizedDescription.contains("isn't JSON"))
        }
        XCTAssertThrowsError(try GraphQL.parseSchema(Data(#"{"ok":true}"#.utf8))) { err in
            XCTAssertTrue(err.localizedDescription.contains("GraphQL"))
        }
    }

    // MARK: Selection

    func testDefaultSelection() throws {
        // Leaves only, preferred first; deprecated and arg-requiring leaves skipped.
        XCTAssertEqual(GraphQL.defaultSelection(for: try field("countries"), in: schema), ["code", "name", "emoji", "capital"])
        XCTAssertEqual(GraphQL.defaultSelection(for: try field("version"), in: schema), [])
        XCTAssertEqual(GraphQL.defaultSelection(for: try field("search"), in: schema),
                       ["on:Country.code", "on:Country.name", "on:Country.emoji", "on:Country.capital",
                        "on:User.id", "on:User.name", "on:User.email"])
        let wrapper = GQLField(name: "wrapper", args: [], type: .named("Wrapper"), isDeprecated: false)
        XCTAssertEqual(GraphQL.defaultSelection(for: wrapper, in: schema), ["user.id", "user.name", "user.email"])
    }

    // MARK: Build

    func testBuildCountryExact() throws {
        let r = GraphQL.buildOperation(.query, field: try field("country"), selection: ["name", "capital", "languages.name"],
                                       args: ["code": "IN"], schema: schema)
        XCTAssertEqual(r.query, """
        query GetCountry($code: ID!) {
          country(code: $code) {
            name
            capital
            languages {
              name
            }
          }
        }
        """)
        XCTAssertEqual(r.variables, "{\n  \"code\": \"IN\"\n}")
        XCTAssertEqual(GraphQL.format(r.query), r.query)
        XCTAssertEqual(GraphQL.operationName(in: r.query), "GetCountry")
    }

    func testBuildValueConversions() throws {
        let r = GraphQL.buildOperation(.query, field: try field("countries"), selection: ["code"], args: [
            "first": "5", "withEmoji": "true", "sort": "DESC", "codes": #"["IN","US"]"#,
            "filter": #"{"code":{"eq":"IN"}}"#,
        ], schema: schema)
        XCTAssertTrue(r.query.hasPrefix(
            "query GetCountries($filter: CountryFilterInput, $first: Int, $sort: Sort, $withEmoji: Boolean, $codes: [ID!]) {\n"
            + "  countries(filter: $filter, first: $first, sort: $sort, withEmoji: $withEmoji, codes: $codes) {"))
        let v = try vars(r.variables)
        XCTAssertEqual(v["first"] as? Int, 5)
        XCTAssertEqual(v["withEmoji"] as? Bool, true)
        XCTAssertEqual(v["sort"] as? String, "DESC")
        XCTAssertEqual(v["codes"] as? [String], ["IN", "US"])
        XCTAssertEqual((v["filter"] as? [String: [String: String]])?["code"]?["eq"], "IN")
        // key order follows arg order
        XCTAssertLessThan(r.variables.range(of: "filter")!.lowerBound, r.variables.range(of: "codes")!.lowerBound)

        // Unparsable values fall back to strings; quoted text is accepted as-is.
        let bad = GraphQL.buildOperation(.query, field: try field("countries"), selection: [], args: [
            "first": "lots", "codes": "IN", "filter": "{oops",
        ], schema: schema)
        let bv = try vars(bad.variables)
        XCTAssertEqual(bv["first"] as? String, "lots")
        XCTAssertEqual(bv["codes"] as? String, "IN")
        XCTAssertEqual(bv["filter"] as? String, "{oops")
        let quoted = GraphQL.buildOperation(.query, field: try field("country"), selection: [], args: ["code": "\"IN\""], schema: schema)
        XCTAssertEqual(try vars(quoted.variables)["code"] as? String, "IN")
    }

    func testEmptyOptionalOmittedAndRequiredPlaceholder() throws {
        let r = GraphQL.buildOperation(.query, field: try field("countries"), selection: [],
                                       args: ["first": "  ", "sort": ""], schema: schema)
        XCTAssertTrue(r.query.hasPrefix("query GetCountries {\n  countries {\n"))
        XCTAssertEqual(r.variables, "{}")
        // empty selection → default leaves
        XCTAssertTrue(r.query.contains("    code\n    name\n    emoji\n    capital\n"))

        let c = GraphQL.buildOperation(.query, field: try field("country"), selection: ["name"], args: [:], schema: schema)
        XCTAssertTrue(c.query.contains("country(code: $code)"))
        XCTAssertEqual(try vars(c.variables)["code"] as? String, "")

        let m = GraphQL.buildOperation(.mutation, field: try field("createUser", .mutation), selection: [], args: [:], schema: schema)
        let input = try XCTUnwrap(try vars(m.variables)["input"] as? [String: Any])
        XCTAssertEqual(input["email"] as? String, "")
        XCTAssertEqual(input["age"] as? Int, 0)
        XCTAssertNil(input["nickname"])
    }

    func testUnionInlineFragments() throws {
        let r = GraphQL.buildOperation(.query, field: try field("search"),
                                       selection: ["on:User.name", "on:Country.code", "on:Country.languages.name"],
                                       args: ["term": "in"], schema: schema)
        XCTAssertEqual(r.query, """
        query GetSearch($term: String!) {
          search(term: $term) {
            __typename
            ... on Country {
              code
              languages {
                name
              }
            }
            ... on User {
              name
            }
          }
        }
        """)
        XCTAssertEqual(GraphQL.format(r.query), r.query)
    }

    func testMutationNamingAndLeafRoot() throws {
        let m = GraphQL.buildOperation(.mutation, field: try field("createUser", .mutation), selection: ["id"],
                                       args: ["input": #"{"email":"a@b.c","age":30}"#], schema: schema)
        XCTAssertEqual(m.query, """
        mutation CreateUser($input: CreateUserInput!) {
          createUser(input: $input) {
            id
          }
        }
        """)
        XCTAssertEqual((try vars(m.variables)["input"] as? [String: Any])?["age"] as? Int, 30)

        let v = GraphQL.buildOperation(.query, field: try field("version"), selection: ["x"], args: [:], schema: schema)
        XCTAssertEqual(v.query, "query GetVersion {\n  version\n}")
        let getter = GQLField(name: "getUser", args: [], type: .named("String"), isDeprecated: false)
        XCTAssertTrue(GraphQL.buildOperation(.query, field: getter, selection: [], args: [:], schema: schema).query
            .hasPrefix("query GetUser {"))
    }

    func testPlaceholders() throws {
        let args = Dictionary(uniqueKeysWithValues: try field("countries").args.map { ($0.name, $0) })
        XCTAssertEqual(GraphQL.placeholder(for: args["first"]!, in: schema), "e.g. 42 (default: 10)")
        XCTAssertEqual(GraphQL.placeholder(for: args["sort"]!, in: schema), "one of: ASC, DESC")
        XCTAssertEqual(GraphQL.placeholder(for: args["withEmoji"]!, in: schema), "true or false")
        XCTAssertEqual(GraphQL.placeholder(for: args["codes"]!, in: schema), #"e.g. ["1"]"#)
        XCTAssertEqual(GraphQL.placeholder(for: try field("country").args[0], in: schema), #"e.g. "1""#)
        XCTAssertEqual(GraphQL.placeholder(for: try field("createUser", .mutation).args[0], in: schema),
                       #"{"email":"","age":0}"#)
    }

    // MARK: Format & helpers

    func testFormat() {
        let messy = #"query   GetX($id:ID!,$n:Int=3, $f: [String!]! = ["a" "b"]){user(id:$id,filter:{a:{eq:"x, y"}}){ name,  # who"#
            + "\n" + #"posts(first:$n) @include(if:true){title}  ... on Admin{level} ...Frag}}"#
            + "\nfragment Frag on User{id}"
        let expected = """
        query GetX($id: ID!, $n: Int = 3, $f: [String!]! = ["a", "b"]) {
          user(id: $id, filter: { a: { eq: "x, y" } }) {
            name # who
            posts(first: $n) @include(if: true) {
              title
            }
            ... on Admin {
              level
            }
            ...Frag
          }
        }

        fragment Frag on User {
          id
        }
        """
        XCTAssertEqual(GraphQL.format(messy), expected)
        XCTAssertEqual(GraphQL.format(expected), expected)
        XCTAssertEqual(GraphQL.format("{a{b}}"), "{\n  a {\n    b\n  }\n}")
        // Broken input is returned untouched.
        XCTAssertEqual(GraphQL.format("query { a { b }"), "query { a { b }")
        XCTAssertEqual(GraphQL.format("query { a(x: \"unterminated) }"), "query { a(x: \"unterminated) }")
        XCTAssertEqual(GraphQL.format(GraphQL.introspectionQuery), GraphQL.format(GraphQL.format(GraphQL.introspectionQuery)))
    }

    func testOperationName() {
        XCTAssertEqual(GraphQL.operationName(in: "# c\nquery Foo { a }"), "Foo")
        XCTAssertEqual(GraphQL.operationName(in: "fragment F on X { a }\nmutation Bar($x: Int) { b }"), "Bar")
        XCTAssertNil(GraphQL.operationName(in: "{ query }"))
        XCTAssertNil(GraphQL.operationName(in: "query { a }"))
    }

    func testRequestBody() throws {
        func obj(_ s: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
        let q = "query GetCountry($code: ID!) {\n  country(code: $code) { name }\n}"
        let b = try obj(GraphQL.requestBody(query: q, variables: #"{"code":"IN"}"#))
        XCTAssertEqual(b["query"] as? String, q)
        XCTAssertEqual((b["variables"] as? [String: String])?["code"], "IN")
        XCTAssertEqual(b["operationName"] as? String, "GetCountry")
        let anon = try obj(GraphQL.requestBody(query: "{ a }", variables: "{not json"))
        XCTAssertEqual(Set(anon.keys), ["query"])
        XCTAssertEqual(Set(try obj(GraphQL.requestBody(query: "{ a }", variables: "  ")).keys), ["query"])
    }

    func testErrors() {
        let body = Data(#"""
        {"errors":[{"message":"Cannot query field \"foo\" on type \"Query\".","locations":[{"line":2,"column":3}]},
                   {"message":"Boom","path":["countries",0,"name"]}],"data":null}
        """#.utf8)
        XCTAssertEqual(GraphQL.errors(in: body), [
            #"Cannot query field "foo" on type "Query". (line 2:3)"#,
            "Boom at countries.0.name",
        ])
        XCTAssertTrue(GraphQL.looksLikeGraphQLResponse(body))
        XCTAssertEqual(GraphQL.errors(in: Data(#"{"data":{"a":1}}"#.utf8)), [])
        XCTAssertTrue(GraphQL.looksLikeGraphQLResponse(Data(#"{"data":{"a":1}}"#.utf8)))
        XCTAssertEqual(GraphQL.errors(in: Data("nope".utf8)), [])
        XCTAssertFalse(GraphQL.looksLikeGraphQLResponse(Data(#"{"items":[]}"#.utf8)))
    }

    func testHighlightDoesNotCrash() {
        let s = NSTextStorage(string: "query Q($id: ID!) { a(x: \"#no\", n: 3) # hi\n ... on User { id } }")
        GraphQL.highlight(s)
        let color = { (i: Int) in s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color(0), .systemPink)                       // query
        XCTAssertEqual(color(8), .systemPurple)                     // $id
        XCTAssertEqual(color(13), .systemTeal)                      // ID
        XCTAssertEqual(color(26), .systemOrange)                    // "#no"
        XCTAssertEqual(color(s.string.distance(from: s.string.startIndex, to: s.string.range(of: "# hi")!.lowerBound)),
                       .secondaryLabelColor)
    }

    // MARK: Live (optional)

    func testLiveCountriesAPI() async throws {
        let url = URL(string: "https://countries.trevorblades.com/")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 8
        let session = URLSession(configuration: cfg)
        func post(_ body: String) async throws -> Data {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
            do { return try await session.data(for: req).0 } catch { throw XCTSkip("Network unavailable: \(error.localizedDescription)") }
        }
        let live = try GraphQL.parseSchema(try await post(GraphQL.requestBody(query: GraphQL.introspectionQuery, variables: "")))
        let names = live.rootFields(.query).map(\.name)
        XCTAssertTrue(names.contains("countries"))
        let country = try XCTUnwrap(live.rootFields(.query).first { $0.name == "country" })
        let op = GraphQL.buildOperation(.query, field: country, selection: [], args: ["code": "IN"], schema: live)
        let resp = try await post(GraphQL.requestBody(query: op.query, variables: op.variables))
        XCTAssertEqual(GraphQL.errors(in: resp), [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: resp) as? [String: Any])
        let name = ((json["data"] as? [String: Any])?["country"] as? [String: Any])?["name"] as? String
        XCTAssertEqual(name, "India")
    }
}
