#!/usr/bin/env bash
# UserPromptSubmit hook: reminds Claude to write its final response in
# ASD-STE100 (Simplified Technical English) style. Solve the task first,
# then apply this style to the response text.
jq -n '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: (
      "Style reminder (ASD-STE100 / Simplified Technical English) — apply this to your FINAL response text only, after you have solved the request: " +
      "Use short, simple sentences. Put one idea in each sentence. Use common, concrete words. " +
      "Avoid unnecessary technical or complex words, idioms, metaphors, slang, and other figurative language. " +
      "Avoid long sentences and nested clauses. The first time you use a technical term, define it in plain English; after that, use the same term every time for the same concept. " +
      "Prefer active voice. Remove unnecessary words. " +
      "This is a style constraint, not a length requirement: do not pad or lengthen the response to satisfy it, and do not drop needed technical meaning. Keep the answer concise and accurate."
    )
  }
}'
