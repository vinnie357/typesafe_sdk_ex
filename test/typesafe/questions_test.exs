defmodule TypeSafe.QuestionsTest do
  use ExUnit.Case, async: true

  alias TypeSafe.StubAdapter

  @system_one_response ~s({"model":"m","answers":{},"usage":{"input_tokens":1,"output_tokens":1}})

  # docs/spec.md §11 S4 #1 (client.test.ts:344,353)
  test "noul/0 returns instructions nil with no criteria key" do
    assert TypeSafe.noul() == %{type: "noul", instructions: nil}
    refute Map.has_key?(TypeSafe.noul(), :criteria)
  end

  # docs/spec.md §11 S4 #2 (client.test.ts:278-279)
  test "noul/1 omits the criteria key" do
    assert TypeSafe.noul("x") == %{type: "noul", instructions: "x"}
    refute Map.has_key?(TypeSafe.noul("x"), :criteria)
  end

  # docs/spec.md §11 S4 #3 (client.test.ts:278-287,329)
  test "noul/2 accepts one side, both sides, or nil criteria" do
    assert TypeSafe.noul("q", %{true: "yes means this"}) ==
             %{type: "noul", instructions: "q", criteria: %{true: "yes means this"}}

    assert TypeSafe.noul("q", %{false: "no means this"}).criteria == %{false: "no means this"}
    assert TypeSafe.noul("q", %{true: "a", false: "b"}).criteria == %{true: "a", false: "b"}
    assert TypeSafe.noul("q", nil) == %{type: "noul", instructions: "q", criteria: nil}
  end

  # docs/spec.md §11 S4 #4 (client.test.ts:263-269)
  test "choice passes the criteria map through untouched" do
    assert TypeSafe.choice("q", %{a: "desc", b: nil}) ==
             %{type: "choice", instructions: "q", criteria: %{a: "desc", b: nil}}
  end

  # docs/spec.md §11 S4 #5 (client.test.ts:271-276)
  test "choice with a list raises FunctionClauseError" do
    assert_raise FunctionClauseError, fn -> TypeSafe.choice("q", ["a", "b"]) end
  end

  # docs/spec.md §11 S4 #6 (client.test.ts:315-321)
  test "score keeps the given list and raises on a map" do
    assert TypeSafe.score("q", ["bad", "good"]) ==
             %{type: "score", instructions: "q", criteria: ["bad", "good"]}

    assert_raise FunctionClauseError, fn ->
      TypeSafe.score("q", %{0 => "bad", 1 => "good"})
    end
  end

  # docs/spec.md §11 S4 #7 (client.test.ts:289-294)
  test "descriptions may be maps or lists, not only strings" do
    rich = %{summary: "warm", examples: ["hi!", "welcome"]}

    assert TypeSafe.choice("q", %{friendly: rich, hostile: nil}).criteria.friendly == rich
    assert Enum.at(TypeSafe.score("q", [rich, "meh"]).criteria, 0) == rich
    assert TypeSafe.noul("q", %{true: rich}).criteria[true] == rich
  end

  # docs/spec.md §11 S4 #8 (client.test.ts:325-335)
  test "wire preserves nil state, instructions, and criteria" do
    questions = %{
      noul: TypeSafe.noul(nil, %{true: nil, false: nil}),
      no_criteria: TypeSafe.noul(nil, nil),
      choice: TypeSafe.choice(nil, %{yes: nil, no: nil}),
      score: TypeSafe.score(nil, [nil, "high"])
    }

    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))
    assert {:ok, _result} = TypeSafe.system_one(client, %{state: nil, questions: questions})
    assert_received {:sent, request}
    assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(request.body))

    assert decoded == %{
             "model" => "jev-latest",
             "state" => nil,
             "questions" => %{
               "noul" => %{
                 "type" => "noul",
                 "instructions" => nil,
                 "criteria" => %{"true" => nil, "false" => nil}
               },
               "no_criteria" => %{"type" => "noul", "instructions" => nil, "criteria" => nil},
               "choice" => %{
                 "type" => "choice",
                 "instructions" => nil,
                 "criteria" => %{"yes" => nil, "no" => nil}
               },
               "score" => %{"type" => "score", "instructions" => nil, "criteria" => [nil, "high"]}
             }
           }
  end

  # docs/spec.md §11 S4 #9 (client.test.ts:337-356)
  test "wire allows omitted instructions, nested lists, and raw question maps" do
    questions = %{
      noul: %{type: "noul", criteria: nil},
      choice: %{type: "choice", criteria: %{yes: [nil, %{example: true}]}},
      score: %{type: "score", criteria: [[nil, "low"], nil]},
      array_instructions: TypeSafe.noul([nil, %{examples: [1, false]}], %{true: ["yes", nil]}),
      default_instructions: TypeSafe.noul()
    }

    state = [nil, %{messages: ["hello"]}]

    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))
    assert {:ok, _result} = TypeSafe.system_one(client, %{state: state, questions: questions})
    assert_received {:sent, request}
    assert {:ok, decoded} = JSON.decode(IO.iodata_to_binary(request.body))

    assert decoded == %{
             "model" => "jev-latest",
             "state" => [nil, %{"messages" => ["hello"]}],
             "questions" => %{
               "noul" => %{"type" => "noul", "criteria" => nil},
               "choice" => %{
                 "type" => "choice",
                 "criteria" => %{"yes" => [nil, %{"example" => true}]}
               },
               "score" => %{"type" => "score", "criteria" => [[nil, "low"], nil]},
               "array_instructions" => %{
                 "type" => "noul",
                 "instructions" => [nil, %{"examples" => [1, false]}],
                 "criteria" => %{"true" => ["yes", nil]}
               },
               "default_instructions" => %{"type" => "noul", "instructions" => nil}
             }
           }
  end

  # docs/spec.md §11 S4 #10 (client.test.ts:367-375)
  test "choice and score criteria are sent without rewriting" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    assert {:ok, _result} =
             TypeSafe.system_one(client, %{
               state: "s",
               questions: %{q: TypeSafe.choice("which?", %{a: nil, b: nil})}
             })

    assert_received {:sent, request1}

    assert {:ok, %{"questions" => %{"q" => %{"criteria" => choice_criteria}}}} =
             JSON.decode(IO.iodata_to_binary(request1.body))

    assert choice_criteria == %{"a" => nil, "b" => nil}

    assert {:ok, _result} =
             TypeSafe.system_one(client, %{
               state: "s",
               questions: %{q: TypeSafe.score("q", ["bad", "ok", "great"])}
             })

    assert_received {:sent, request2}

    assert {:ok, %{"questions" => %{"q" => %{"criteria" => score_criteria}}}} =
             JSON.decode(IO.iodata_to_binary(request2.body))

    assert score_criteria == ["bad", "ok", "great"]
  end

  # docs/spec.md §11 S4 #11 (client.test.ts:296-313)
  test "choice answer is decoded with the winning label" do
    body =
      ~s({"model":"m","answers":{"q":{"type":"choice","choice":"b","confidence":0.9,"probabilities":{"a":0.1,"b":0.9}}},"usage":{"input_tokens":1,"output_tokens":1}})

    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, body))

    assert {:ok, result} =
             TypeSafe.system_one(client, %{
               state: "s",
               questions: %{q: TypeSafe.choice("q", %{a: nil, b: nil})}
             })

    assert result["answers"]["q"]["choice"] == "b"
  end

  # docs/spec.md §11 S4 #12 (client.test.ts:377-395)
  test "empty questions returns an error and sends zero requests" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    assert {:error, %TypeSafe.Error{message: message}} =
             TypeSafe.system_one(client, %{state: "s", questions: %{}})

    assert message == "At least one question is required."
    refute_received {:sent, _request}
  end

  # docs/spec.md §11 S4 #13 (client.test.ts:377-395)
  test "score criteria as a map returns an error naming the question" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    bad_question = %{type: "score", criteria: %{0 => "bad", 1 => "ok"}}

    assert {:error, %TypeSafe.Error{message: message}} =
             TypeSafe.system_one(client, %{state: "s", questions: %{q: bad_question}})

    assert message ==
             ~s(Score question "q" has criteria that are not a list; score criteria must be a list of descriptions indexed by score from zero.)

    refute_received {:sent, _request}
  end

  # docs/spec.md §11 S4 #14 (client.test.ts:377-395)
  test "score criteria with fewer than two entries returns an error" do
    assert {:ok, client} = StubAdapter.client(StubAdapter.respond(200, @system_one_response))

    assert {:error, %TypeSafe.Error{message: empty_message}} =
             TypeSafe.system_one(client, %{
               state: "s",
               questions: %{q: %{type: "score", criteria: []}}
             })

    assert empty_message ==
             ~s(Score question "q" has 0 criteria; at least two scores are required.)

    assert {:error, %TypeSafe.Error{message: one_message}} =
             TypeSafe.system_one(client, %{
               state: "s",
               questions: %{q: %{type: "score", criteria: ["only"]}}
             })

    assert one_message == ~s(Score question "q" has 1 criteria; at least two scores are required.)

    refute_received {:sent, _request}
  end
end
