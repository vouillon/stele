open Util
open Grammar
open Config

(* --- Name-rendering provenance (the [names] review mode) --- *)

(* The pipeline step that produced a rendered name, so [stele names] can report
   *how* every symbol reached its wording. Mirrors the precedence documented in
   stele's README: a token alias, a [names] config entry, the list-element
   chase, the pluralised Assuming-subject rendering, the lowercase
   auto-derivation, a [class] label, or the last-resort quoted-lowercase
   fallback. Recorded alongside each rendered string by the [*_src] variants of
   the rendering functions, kept non-invasive (the plain functions project the
   string out). *)
type name_source =
  | Alias
  | Names_entry
  | Chase
  | Plural_subject
  | Auto
  | Class_label
  | Fallback

let source_label = function
  | Alias -> "alias"
  | Names_entry -> "[names]"
  | Chase -> "list-element"
  | Plural_subject -> "plural-subject"
  | Auto -> "auto-derived"
  | Class_label -> "[class]"
  | Fallback -> "quoted-fallback"

(* Where a rendered name appears. Usage is counted per position because a symbol
   can render differently in each — a list-shaped nonterminal singularises via
   the chase in the Expecting list but keeps its list/plural name as an Assuming
   subject — and a [names] entry can be dead in one position yet live in the
   other (the [LPAREN_IMPORT]/[list_of_indices] subtlety). *)
type position = Expecting | Assuming

(* One rendering of one grammar symbol in one position of one message — the raw
   material [stele names] and the config-unused stat aggregate over. [nu_credit]
   names the element a list-element chase resolved to and *its* real source: when
   [nu_source] is [Chase] the shown text comes from that element (e.g. the
   [locals] list chases to [local_decl], whose text is its [names] entry), so
   the config-unused stat credits the element and does not mis-report it as
   unused. [None] when no chase occurred. *)
type name_use = {
  nu_symbol : string;
  nu_rendered : string;
  nu_source : name_source;
  nu_position : position;
  nu_credit : (string * name_source) option;
}

(* --- Message Generation --- *)

let format_human_list items =
  match List.rev items with
  | [] -> ""
  | [ x ] -> x
  | [ y; x ] -> x ^ " or " ^ y
  | last :: rest -> String.concat ", " (List.rev rest) ^ ", or " ^ last

(* Curated readable name for a symbol whose auto-derived rendering would be
   internal jargon or grammatically wrong (e.g. "a blockinstr", "a mem limits");
   [None] falls through to the derivation in [get_readable_name]. Read from the
   config file's [names] section rather than hard-coded, so the generator
   itself is grammar-agnostic. *)
let special_name cfg s = Hashtbl.find_opt cfg.names s

(* Collapse a token class (e.g. the many infix operators) into a single readable
   label *before* the <=5 cap, so a state whose FOLLOW is "a closer or any
   operator" reads "Expecting ')' or an operator." instead of overflowing to the
   generic fallback. The classes are read from the config file ([class LABEL]
   sections); a token in no class returns [None] and keeps its precise spelling.
   The first class the token appears in wins (file order). *)
let classify_symbol cfg s =
  List.find_map
    (fun (label, members) ->
      if StringSet.mem s members then Some label else None)
    cfg.classes

(* Does a noun phrase read as plural? Decided by its LAST word — "descriptor
   clauses" is plural, "expression list" is not — so an article or a verb can
   agree with the head noun. A final 's' marks a plural, except in a few common
   words that end in 's' anyway. *)
let is_plural_phrase phrase =
  match List.rev (String.split_on_char ' ' phrase) with
  | last :: _ ->
      String.length last > 1
      && last.[String.length last - 1] = 's'
      && not (List.mem last [ "as"; "is"; "this"; "plus"; "minus"; "address" ])
  | [] -> false

(* Core rendering with provenance. Returns the readable string paired
   with the pipeline step that produced it; [get_readable_name] projects the
   string. Precedence: token alias, [names] entry, lowercase auto-derivation,
   quoted-lowercase fallback. *)
let get_readable_name_src cfg terminals s =
  match Hashtbl.find_opt terminals s with
  | Some a -> (Printf.sprintf "'%s'" a, Alias)
  | None -> (
      (* An opaque parameterized instantiation (a phantom-parameter split like
         [function_type(in_type)]) renders by its base head: the [names] lookup
         and the noun-phrase derivation see [function_type], not the argument
         list. Terminals never carry a '(', so this only affects nonterminals;
         wrapper instantiations are expanded upstream and never reach here. *)
      let s = base_symbol_name s in
      match special_name cfg s with
      | Some name -> (name, Names_entry)
      | None ->
          if String.lowercase_ascii s = s then
            (* Non-terminals: "some_name" -> "a/an some name" *)
            let parts = String.split_on_char '_' s in
            let parts = List.filter (fun p -> p <> "") parts in
            if parts = [] then (s, Auto)
            else
              let name = String.concat " " parts in
              match parts with
              | p :: _ ->
                  let c = String.get p 0 in
                  (* Drop the article for a plural noun phrase ("folded
                     instructions", not "a folded instructions"). *)
                  if is_plural_phrase name then (name, Auto)
                  else if List.mem c [ 'a'; 'e'; 'i'; 'o'; 'u' ] then
                    ("an " ^ name, Auto)
                  else ("a " ^ name, Auto)
              | _ -> (name, Auto)
          else
            (* Keywords/Other Terminals: "TOKEN" -> "'token'" *)
            ("'" ^ String.lowercase_ascii s ^ "'", Fallback))

(* Rendering for the *Expecting* position. What the user types next is
   one element, so a list-shaped nonterminal is rendered as its singular element
   ("Expecting ')' or an instruction.") rather than the list ("… or
   instructions."). For a user-named, list-shaped nonterminal the chase names the
   common element symbol and renders *that* recursively (a terminal by its alias,
   another nonterminal by its own reading — itself possibly list-shaped); every
   other symbol, and the *Assuming* subject, keep [get_readable_name]. The chase
   overrides a curated [special_name] for a list-shaped name when it fires
   (e.g. [list_of_indices] → "an index", [on_clauses] → the [on]/[[] opener),
   which is intentional; the curated forms remain in force for the Assuming
   subject, which names the whole completed sequence. *)
(* Returns (rendered string, display source, credit). When the list-element chase fires
   the display source is [Chase] (so the review table shows the mechanism that
   overrode the list name), and the credit is the element the chase resolved to
   paired with its *real* source — what actually produced the text. *)
let rec expecting_name_src ?(visited = StringSet.empty) cfg terminals gram s =
  if
    (not (Hashtbl.mem terminals s))
    && String.lowercase_ascii s = s
    && (not (gram.is_terminal s))
    && (not (gram.is_generated s))
    && (not (StringSet.mem s visited))
    && is_list_shaped gram s
  then
    match chase_list_element gram s with
    | Some elem ->
        let r, elem_src, elem_credit =
          expecting_name_src ~visited:(StringSet.add s visited) cfg terminals
            gram elem
        in
        (* The credit is the deepest resolution: propagate the element's own
           credit if it was itself chased, else the element and its real
           source. *)
        let credit =
          match elem_credit with Some c -> c | None -> (elem, elem_src)
        in
        (r, Chase, Some credit)
    | None ->
        let r, src = get_readable_name_src cfg terminals s in
        (r, src, None)
  else
    let r, src = get_readable_name_src cfg terminals s in
    (r, src, None)

let expecting_name ?(visited = StringSet.empty) cfg terminals gram s =
  let r, _, _ = expecting_name_src ~visited cfg terminals gram s in
  r

(* Drop a leading indefinite article from a readable noun phrase
   ("a field type" -> "field type", "an elemexpr" -> "elemexpr"); a quoted
   terminal or an already-article-less phrase is returned unchanged. *)
let strip_article name =
  if String.length name > 2 && String.sub name 0 2 = "a " then
    String.sub name 2 (String.length name - 2)
  else if String.length name > 3 && String.sub name 0 3 = "an " then
    String.sub name 3 (String.length name - 3)
  else name

(* Pluralise the head (last word) of a readable noun phrase, so a *list*
   subject reads "the value types are complete" rather than the singular. The
   rule is the regular English one (…es after a sibilant, so "catch" ->
   "catches"); an irregular head noun can be curated in [special_name]. *)
let pluralize_phrase name =
  match List.rev (String.split_on_char ' ' name) with
  | [] | [ "" ] -> name
  | last :: rest ->
      let n = String.length last in
      let ends suf =
        let ls = String.length suf in
        n >= ls && String.sub last (n - ls) ls = suf
      in
      let plural =
        if ends "s" || ends "x" || ends "z" || ends "ch" || ends "sh" then
          last ^ "es"
        else last ^ "s"
      in
      String.concat " " (List.rev (plural :: rest))

(* Rendering for the *Assuming that the X is complete* subject. A user-named
   nonterminal names the completed construct directly ("the block type is
   complete"). A menhir-generated symbol — always a list wrapper when it reaches
   [%on_error_reduce], since that is the only reason to annotate one — would
   otherwise render as its raw internal name ("the list(field type) is
   complete", jargon); instead chase its element and pluralise it ("the field
   types are complete"). The [%on_error_reduce] reductions that reach here are
   frequently *epsilon* (an empty list assumed complete), so this subject is what
   signals to the reader that an optional list element was elided from the
   Expecting list rather than being illegal — the hedge whose absence silently
   dropped tokens. *)
let subject_name_src cfg terminals gram s =
  if gram.is_generated s then
    match chase_list_element gram s with
    | Some elem ->
        ( pluralize_phrase
            (strip_article (expecting_name cfg terminals gram elem)),
          Plural_subject )
    | None -> ("a list", Plural_subject)
  else get_readable_name_src cfg terminals s

let renders_as_jargon cfg terminals s =
  String.uppercase_ascii s = s
  && (not (Hashtbl.mem terminals s))
  && special_name cfg s = None
  && String.contains s '_'

(* Code abbreviations that read as internal jargon in a user-facing message. A
   nonterminal's auto-derived name is its identifier with the underscores turned
   into spaces, so a rule named for the implementer's convenience —
   [compilation_priority_annot], [instr_freq_payload] — surfaces verbatim as "a
   compilation priority annot". The list is grammar-agnostic on purpose: these are
   how programmers shorten words, not anything about a particular grammar, so a new
   grammar inherits the lint with no configuration.

   Deliberately not here: whole words that merely read oddly ("payload", "body",
   "item"). Those are judgement calls, and a word list that tried to make them
   would produce false positives on names that are fine. This catches the
   mechanical, unarguable cases; the [names] entry remains the fix for the rest. *)
let jargon_words =
  [
    "annot";
    "arg";
    "args";
    "attr";
    "attrs";
    "aux";
    "cond";
    "conds";
    "ctx";
    "decl";
    "decls";
    "def";
    "defs";
    "elt";
    "elts";
    "expr";
    "exprs";
    "fn";
    "freq";
    "idx";
    "impl";
    "instr";
    "instrs";
    "num";
    "opt";
    "opts";
    "param";
    "params";
    "pat";
    "pats";
    "ptr";
    "ref";
    "refs";
    "req";
    "res";
    "sep";
    "stmt";
    "stmts";
    "tmp";
    "val";
    "vals";
    "var";
    "vars";
  ]

(* Whether an auto-derived rendering contains one of those. Words are compared
   whole (so "reference" is not flagged for containing "ref"), and the leading
   article the derivation added is skipped. *)
let rendering_has_jargon_word rendered =
  String.split_on_char ' ' rendered
  |> List.exists (fun w ->
      (not (w = "a" || w = "an"))
      && List.mem (String.lowercase_ascii w) jargon_words)
