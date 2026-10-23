(* stele's generator: turns a Menhir grammar's [--list-errors] sentences and its
   [.cmly] into user-friendly syntax-error messages, and also drives the
   stats/census/names review modes and the [stele tune] annotation advisor. The
   generation heuristics, the sidecar file formats, and the review workflow are
   documented for users in stele's README and TUTORIAL.

   This file is the command line. The modules, in dependency order:
   - [Parse_messages]: the [menhir --list-errors] parser;
   - [Util]: string sets and maps, small helpers;
   - [Grammar]: the [.cmly] reader and the continuation (FIRST-set) walk;
   - [Config]: the [--config] sidecar and its rot check;
   - [Naming]: how a symbol is turned into words;
   - [Delimiters]: opener/closer pairing and the delimiter-hint depth;
   - [Overrides]: the [--overrides] sidecar and its checks;
   - [Generate]: [generate_message], the core per-state rendering;
   - [Reports]: the stats/census/names/fallbacks/suggest-classes/transitions
     outputs and the soundness oracle;
   - [Tune]: [stele tune]. *)

open Util
open Config
open Overrides
open Generate
open Reports
open Tune

(* --- Main Entry Point --- *)

(* The output mode, one per subcommand. [Generate] carries the [--no-comments]
   flag; every other mode is a nullary tag. *)
type mode =
  | Generate of bool  (** [true] = [--no-comments] *)
  | Stats
  | Census
  | Names
  | Fallbacks
  | Suggest_classes
  | Transitions

(* Run one mode over the [.messages] file, given the three grammar sidecars
   ([config_file]/[overrides_file] are [""] when not supplied). Every mode
   parses the entries, checks override rot, loads the [.cmly] grammar (and the
   config, checking its rot too), then dispatches on [mode]. The rot guards
   raise [Failure], caught at the top level and rendered as a clean one-line
   error. *)
let run mode ~cmly_file ~config_file ~overrides_file input_file =
  let entries = Parse_messages.parse_file input_file in
  Printf.eprintf "Parsed %d entries from %s\n" (List.length entries) input_file;
  let overrides =
    if overrides_file = "" then StringMap.empty
    else load_overrides overrides_file
  in
  (* Rot protection: every override must still key a live error state, in every
     mode, so a stale entry can never sit silently in the file. *)
  check_override_rot overrides entries;
  let cfg =
    if config_file = "" then empty_config else load_config config_file
  in
  let ctx = load_context cfg cmly_file in
  (* Rot protection: every config entry must still name a live grammar symbol,
     in every config-consuming mode. *)
  if config_file <> "" then check_config_rot ~file:config_file ctx.grammar cfg;
  match mode with
  | Transitions -> analyze_transitions ctx.closers ctx.mates ctx.grammar entries
  | Generate _ | Stats | Census | Names | Fallbacks | Suggest_classes -> (
      let comments = match mode with Generate nc -> not nc | _ -> true in
      (match mode with
      | Generate _ -> Printf.eprintf "Generating messages...\n"
      | _ -> ());
      let results = generate_all ctx ~comments ~overrides entries in
      let stats_of () =
        List.map (fun (entry, (_, _, stat)) -> (entry, stat)) results
      in
      match mode with
      | Generate no_comments ->
          (* The full [.messages] output (with comments) fed to
             [--compile-errors] keeps menhir's order; the stripped
             [--no-comments] golden is sorted by the sentence header
             ([entry_point: sentence]) so entry order stops tracking state
             numbers and a state merge becomes one clean local deletion instead
             of scattered delete+add pairs. *)
          let to_print =
            if no_comments then
              List.stable_sort
                (fun (e1, _) (e2, _) ->
                  String.compare (header_of e1) (header_of e2))
                results
            else results
          in
          List.iter (fun (_, (text, _, _)) -> print_string text) to_print
      | Census ->
          output_census (List.map (fun (_, (_, body, _)) -> body) results)
      | Stats -> output_stats cfg ctx.grammar ctx.auto (stats_of ())
      | Names ->
          output_names ~overrides_active:(overrides_file <> "") cfg
            (stats_of ())
      | Fallbacks -> output_fallbacks (stats_of ())
      | Suggest_classes -> output_suggest_classes cfg (stats_of ())
      | Transitions -> assert false)

(* --- Command-line interface (cmdliner) --- *)

open Cmdliner
open Term.Syntax

(* The three shared grammar sidecars and the positional [.messages] file, common
   to every subcommand. *)
let cmly_arg =
  let doc =
    "Path to the grammar's $(b,.cmly) file (produced by $(b,menhir --cmly)): \
     the source of exact productions, nullability, and token aliases. Required \
     by every command."
  in
  Arg.(required & opt (some string) None & info [ "cmly" ] ~docv:"FILE" ~doc)

let config_arg =
  let doc =
    "Path to the grammar's $(b,.config) sidecar: readable names, token \
     classes, opener-name nets, and extra wrapper rules. Optional; absent \
     means no curated names and no classes."
  in
  Arg.(value & opt string "" & info [ "config" ] ~docv:"FILE" ~doc)

let overrides_arg =
  let doc =
    "Path to the grammar's hand-written $(b,.overrides) file: sentence-keyed \
     replacement messages for the states heuristics cannot serve, merged after \
     generation. An override whose sentence matches no error state fails the \
     build. Optional."
  in
  Arg.(value & opt string "" & info [ "overrides" ] ~docv:"FILE" ~doc)

let messages_arg =
  let doc =
    "The grammar's $(b,menhir --list-errors) output: one representative error \
     sentence per error state."
  in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"MESSAGES" ~doc)

let no_comments_arg =
  let doc =
    "Omit the auto-generated $(b,##) comments (state numbers, LR items), \
     keeping only the sentence and message, and sort the output by sentence — \
     the stable golden projection."
  in
  Arg.(value & flag & info [ "no-comments" ] ~doc)

let generate_cmd =
  let doc = "Generate the error messages (one per error state)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Emit a syntax-error message for every error state in the \
         $(i,MESSAGES) file: an $(b,Expecting) list of the legal \
         continuations, a delimiter hint, and an $(b,Assuming ... complete) \
         hedge where a reduction folded, with any hand overrides merged in. \
         This is the output that $(b,menhir --compile-errors) turns into a \
         $(b,Parser_messages) module.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ no_comments = no_comments_arg
    and+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run (Generate no_comments) ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "generate" ~doc ~man) term

let stats_cmd =
  let doc = "Print the message-quality summary and self-lints" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print the quality counters (entries, states with an expected list, \
         fallbacks split by whether an override covers them, delimiter hints, \
         missed hints, jargon, cascade depth) and the soundness-oracle lines, \
         plus one dormancy line per configured token class. This is the \
         ratchet: pin it as a golden and a regression fails the build.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Stats ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "stats" ~doc ~man) term

let census_cmd =
  let doc = "Print the distinct message bodies with occurrence counts" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print each distinct message body once, prefixed by its occurrence \
         count and sorted by message text (no sentences appear); the \
         delimiter-hint depth is normalized to $(b,<_>). A wording change is a \
         one-line diff; a sentence re-pick only bumps a count.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Census ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "census" ~doc ~man) term

let names_cmd =
  let doc =
    "Review how every symbol is rendered, and find unused config names"
  in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print a table of every grammar symbol that surfaces in the emitted \
         messages: its rendered form, the pipeline step that produced it \
         (token alias, $(b,[names]) entry, the list-element chase, the \
         Assuming-subject plural rendering, the lowercase auto-derivation, a \
         $(b,[class]) label, or the quoted-lowercase fallback), and how often \
         it appears in the Expecting list versus the Assuming subject. Usage \
         is counted per position because a symbol can render differently in \
         each. After the table, list any $(b,[names]) entries whose curated \
         phrase won in neither position. The audit surface for two directions: \
         awkward renderings that deserve a $(b,[names]) entry, and \
         $(b,[names]) entries nothing uses.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Names ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "names" ~doc ~man) term

let fallbacks_cmd =
  let doc = "Print .overrides templates for uncovered fallback states" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Print a ready-to-paste $(b,.overrides) block for every \
         generic-fallback (\"Syntax error\") state not yet covered by an \
         override: the state's $(b,##) comments, the over-cap candidate list, \
         and the sentence key. Empty output means every fallback is covered.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Fallbacks ~cmly_file:cmly ~config_file:config ~overrides_file:overrides
      messages
  in
  Cmd.v (Cmd.info "fallbacks" ~doc ~man) term

let suggest_classes_cmd =
  let doc = "Propose token-class blocks for the config" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Propose new $(b,[class]) blocks for the $(b,--config) file by \
         signature-clustering the raw expected sets: unclassed terminals that \
         always co-occur, kept at three or more members, ranked by how many \
         entries the collapse newly fits under the readable cap. Empty output \
         means nothing co-occurs tightly enough to be worth a class.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Suggest_classes ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "suggest-classes" ~doc ~man) term

let transitions_cmd =
  let doc = "List every continuation of each error state (debug)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "List, per error state, all possible continuation symbols with \
         lookahead and delimiter-depth annotations — a debugging view of the \
         raw continuation computation.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ cmly = cmly_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ messages = messages_arg in
    run Transitions ~cmly_file:cmly ~config_file:config
      ~overrides_file:overrides messages
  in
  Cmd.v (Cmd.info "transitions" ~doc ~man) term

(* The [tune] subcommand group. Unlike the other modes it does not take
   a prepared [--cmly]/[MESSAGES] pair — it generates those itself, per trial,
   from [--grammar] via a [--menhir] subprocess, in a scratch dir. *)
let grammar_arg =
  let doc =
    "Path to the grammar's $(b,.mly) source. The tuner copies it into a \
     scratch directory and edits its $(b,%on_error_reduce) declarations for \
     each trial; the source tree is never touched. One grammar per invocation."
  in
  Arg.(required & opt (some string) None & info [ "grammar" ] ~docv:"FILE" ~doc)

let menhir_arg =
  let doc =
    "The $(b,menhir) command to run for each trial (a runtime subprocess: \
     $(b,--list-errors) and $(b,--cmly)). It may carry flags, separated by \
     spaces, such as $(b,\"menhir --canonical\") for a grammar built with \
     $(b,--canonical). A clear error is reported if it does not run."
  in
  Arg.(value & opt string "menhir" & info [ "menhir" ] ~docv:"CMD" ~doc)

let verdicts_arg =
  let doc =
    "Path to a recorded keep/remove log: lines $(b,keep NONTERMINAL) / \
     $(b,removed NONTERMINAL) ($(b,#) comments and blanks ignored). Removing a \
     $(b,keep) annotation and re-adding a $(b,removed) one must each score \
     non-improving; the command reports the agreement fraction and every \
     disagreement."
  in
  Arg.(
    required & opt (some string) None & info [ "verdicts" ] ~docv:"FILE" ~doc)

let tune_dead_cmd =
  let doc = "Find %on_error_reduce annotations whose removal changes nothing" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Remove each current $(b,%on_error_reduce) annotation in turn and \
         regenerate; an annotation whose removal leaves the stats, census, and \
         message projection all unchanged is dead and reported for deletion. \
         Trials run override-free (an annotation change re-picks the \
         sentence-keyed overrides), so nothing but the annotation moves.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ menhir = menhir_arg in
    run_tune Tune_dead ~menhir ~config_file:config ~overrides_file:""
      ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "dead" ~doc ~man) term

let tune_advise_cmd =
  let doc = "Rank single add/remove moves by their stats-vector delta" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "For each single move — removing a current annotation, or adding one \
         for a nonterminal reduced somewhere in the automaton — compute the \
         stats-vector delta and classify it. A move is $(b,harmful) when it \
         adds a \"Syntax error\" fallback, an unsound claim, an uncovered \
         token or a missed hint, or loses a delimiter hint. Otherwise it is \
         $(b,improving) when it removes a fallback, an uncovered token or an \
         \"Assuming ...\" hedge; new jargon names (fixed by a config entry) \
         are then only a caveat, but make harmful a move with no such gain. A \
         move that gains hints or un-stacks deep \"Assuming ...\" messages \
         while adding hedges is $(b,mixed); one that changes no message is \
         $(b,dead); anything else is $(b,neutral). Each improving move is \
         priced by its $(b,override-rot) cost (the $(b,--overrides) keys the \
         trial's state re-pick would strand); a move whose whole win lands on \
         already-overridden states is reported separately as \
         $(b,RELOCATES-OVERRIDDEN). The tuner recommends; it never applies, \
         and single-move scores do not compose.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ overrides = overrides_arg
    and+ menhir = menhir_arg in
    run_tune Tune_advise ~menhir ~config_file:config ~overrides_file:overrides
      ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "advise" ~doc ~man) term

let tune_calibrate_cmd =
  let doc = "Replay a recorded keep/remove log and report agreement" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Replay a recorded keep/remove verdict log ($(b,--verdicts)): removing \
         each $(b,keep) annotation and re-adding each $(b,removed) one should \
         score non-improving. Report the agreement fraction and every \
         disagreement — the way to confirm the classifier still reproduces a \
         trusted human audit after the grammar or the stats have changed.";
      `S Manpage.s_options;
    ]
  in
  let term =
    let+ grammar = grammar_arg
    and+ config = config_arg
    and+ menhir = menhir_arg
    and+ verdicts = verdicts_arg in
    run_tune (Tune_calibrate verdicts) ~menhir ~config_file:config
      ~overrides_file:"" ~grammar_file:grammar
  in
  Cmd.v (Cmd.info "calibrate" ~doc ~man) term

let tune_cmd =
  let doc = "Advise on %on_error_reduce annotation moves (read-only)" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "A read-only advisor for a grammar's $(b,%on_error_reduce) list. Each \
         trial re-runs $(b,menhir) (a subprocess) on a scratch copy of the \
         grammar with one annotation added or removed, regenerates the \
         messages in-process, and classifies the move by its effect on the \
         quality counters. It recommends moves; it never applies them and \
         never touches the source tree.";
      `P
        "Trials run WITHOUT the $(b,.overrides) file: an annotation change \
         re-picks the sentence-keyed overrides, so a trial that loaded them \
         could fail the rot guard. $(b,tune advise) still reads them (via \
         $(b,--overrides)) to price each improving move's override-rot cost.";
      `S Manpage.s_commands;
    ]
  in
  Cmd.group
    (Cmd.info "tune" ~doc ~man)
    [ tune_dead_cmd; tune_advise_cmd; tune_calibrate_cmd ]

let main_cmd =
  let doc = "User-friendly syntax-error messages for a Menhir grammar" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "stele turns a Menhir grammar's $(b,--list-errors) output and its \
         $(b,.cmly) into readable syntax-error messages, guarded by promoted \
         golden files so a grammar change shows up as a reviewable message \
         diff rather than silent staleness.";
      `P
        "Every command reads the same inputs: the $(b,--cmly) grammar \
         (required), an optional $(b,--config) sidecar, an optional \
         $(b,--overrides) file, and the positional $(i,MESSAGES) file (the \
         $(b,menhir --list-errors) output).";
      `S Manpage.s_commands;
      `S Manpage.s_examples;
      `P "Generate the messages for $(b,menhir --compile-errors):";
      `Pre
        "  $(mname) generate --cmly g.cmly --config g.config --overrides \
         g.overrides g.messages";
      `P "Print the quality ratchet:";
      `Pre "  $(mname) stats --cmly g.cmly --config g.config g.messages";
    ]
  in
  Cmd.group
    (Cmd.info "stele" ~doc ~man)
    [
      generate_cmd;
      stats_cmd;
      census_cmd;
      names_cmd;
      fallbacks_cmd;
      suggest_classes_cmd;
      transitions_cmd;
      tune_cmd;
    ]

(* A user error (a stale sidecar entry, a malformed input, a missing file)
   raises [Failure] or [Sys_error]; render it as a clean one-line error and exit
   non-zero, rather than letting it escape as an uncaught-exception backtrace.
   [~catch:false] keeps cmdliner from turning it into a generic internal
   error. *)
let () =
  let code =
    try Cmd.eval ~catch:false main_cmd
    with Failure msg | Sys_error msg ->
      Printf.eprintf "stele: %s\n" msg;
      1
  in
  exit code
