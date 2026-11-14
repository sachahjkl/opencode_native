# Reports of background jobs

The harness tells a session that a background job ended with a synthetic message whose text is markup:
`<shell id state command>output</shell>` or `<subagent sessionID state description>report</subagent>`, one or several
in a row. Before, ocn showed its first line raw. Now each report is one card (`src/job_reports.odin`).

## Decisions

- **Read once, at load.** `jobs_parse` runs in `chat_load` and keeps the reports in the chat's arena (`Message.jobs`).
  A build reads no markup. The open card's wells keep their cut text in the report (`Well_Kept`).
- **All or nothing.** The text must be only reports, with whitespace between them. Any other text, an unclosed quote or
  an opening tag without its end makes the message keep its plain line. A wrong card hides text; a plain line hides none.
- **A missing closing tag** makes the body run to the end of the text. A report after it is then read as part of that body.
- **Entities** are read in attribute values only. The body is the job's own output, shown as given.
- **State.** The tag's word goes through `state_of_word`, plus the shell words `exited`, `killed`, `timeout`. A non-zero
  exit code means failed. A failed sub-agent's title carries its reason: the `error` or `reason` attribute, else the
  first line of its report.
- **A metadata sub-agent result stays `subagent_result`.** A synthetic message with `metadata.source = "subagent"` names
  its child and opens it. A harness report has no such link, so its card has no Open button.
- **Folded, a card is its header alone**, so several reports in a row take one line each. The header shows the command's
  first line; its tooltip shows the whole command.
- **The term is "sub-agent"**, as everywhere else in ocn.
