(* $Id$ *)
{
  module Lexing =
    (*
      We override Lexing.engine in order to avoid creating a new position
      record each time a rule is matched.
      This reduces total parsing time by about 31%.
    *)
  struct
    include Lexing

    external c_engine : lex_tables -> int -> lexbuf -> int = "caml_lex_engine"

    let engine tbl state buf =
      let result = c_engine tbl state buf in
      (*
      if result >= 0 then begin
	buf.lex_start_p <- buf.lex_curr_p;
	buf.lex_curr_p <- {buf.lex_curr_p
			   with pos_cnum = buf.lex_abs_pos + buf.lex_curr_pos};
      end;
      *)
      result
  end

  open Printf
  open Lexing


  type lexer_state = {
    buf : Buffer.t;
      (* Buffer used to accumulate substrings *)

    mutable lnum : int;
      (* Current line number (starting from 1) *)

    mutable bol : int;
      (* Absolute position of the first character of the current line 
	 (starting from 0) *)

    mutable fname : string option;
      (* Name describing the input file *)
  }


  let dec c =
    Char.code c - 48

  let hex c =
    match c with
	'0'..'9' -> int_of_char c - int_of_char '0'
      | 'a'..'f' -> int_of_char c - int_of_char 'a' + 10
      | 'A'..'F' -> int_of_char c - int_of_char 'A' + 10
      | _ -> assert false

  let custom_error descr v lexbuf =
    let offs = lexbuf.lex_abs_pos in
    let bol = v.bol in
    let pos1 = offs + lexbuf.lex_start_pos - bol in
    let pos2 = max pos1 (offs + lexbuf.lex_curr_pos - bol - 1) in
    let file_line =
      match v.fname with
	  None -> "Line"
	| Some s ->
	    sprintf "File %s, line" s
    in
    let bytes =
      if pos1 = pos2 then
	sprintf "byte %i" (pos1+1)
      else
	sprintf "bytes %i-%i" (pos1+1) (pos2+1)
    in
    let msg = sprintf "%s %i, %s:\n%s" file_line v.lnum bytes descr in
    json_error msg


  let lexer_error descr v lexbuf =
    custom_error 
      (sprintf "%s '%s'" descr (Lexing.lexeme lexbuf))
      v lexbuf

  let min10 = min_int / 10 - (if min_int mod 10 = 0 then 0 else 1)
  let max10 = max_int / 10 + (if max_int mod 10 = 0 then 0 else 1)

  exception Int_overflow

  let extract_positive_int lexbuf =
    let start = lexbuf.lex_start_pos in
    let stop = lexbuf.lex_curr_pos in
    let s = lexbuf.lex_buffer in
    let n = ref 0 in
    for i = start to stop - 1 do
      if !n >= max10 then
	raise Int_overflow
      else
	n := 10 * !n + dec s.[i]
    done;
    if !n < 0 then
      raise Int_overflow
    else
      !n

  let make_positive_int v lexbuf =
    #ifdef INT
      try `Int (extract_positive_int lexbuf)
      with Int_overflow ->
    #endif
      #ifdef INTLIT
	`Intlit (lexeme lexbuf)
      #else
        lexer_error "Int overflow" v lexbuf
      #endif

  let extract_negative_int lexbuf =
    let start = lexbuf.lex_start_pos + 1 in
    let stop = lexbuf.lex_curr_pos in
    let s = lexbuf.lex_buffer in
    let n = ref 0 in
    for i = start to stop - 1 do
      if !n <= min10 then
	raise Int_overflow
      else
	n := 10 * !n - dec s.[i]
    done;
    if !n > 0 then
      raise Int_overflow
    else
      !n

  let make_negative_int v lexbuf =
    #ifdef INT
      try `Int (extract_negative_int lexbuf)
      with Int_overflow ->
    #endif
      #ifdef INTLIT
	`Intlit (lexeme lexbuf)
      #else
        lexer_error "Int overflow" v lexbuf
      #endif


  let set_file_name v fname =
    v.fname <- fname

  let newline v lexbuf =
    v.lnum <- v.lnum + 1;
    v.bol <- lexbuf.lex_abs_pos + lexbuf.lex_curr_pos;
    printf "lnum=%i bol=%i\n%!" v.lnum v.bol

  let add_lexeme buf lexbuf =
    let len = lexbuf.lex_curr_pos - lexbuf.lex_start_pos in
    Buffer.add_substring buf lexbuf.lex_buffer lexbuf.lex_start_pos len
}

let space = [' ' '\t' '\r']+

let digit = ['0'-'9']
let nonzero = ['1'-'9']
let digits = digit+
let frac = '.' digits
let e = ['e' 'E']['+' '-']?
let exp = e digits

let positive_int = (digit | nonzero digits)
let float = '-'? positive_int (frac | exp | frac exp)
let number = '-'? positive_int (frac | exp | frac exp)?

let hex = [ '0'-'9' 'a'-'f' 'A'-'F' ]

let ident = ['a'-'z' 'A'-'Z' '_']['a'-'z' 'A'-'Z' '_' '0'-'9']*


rule read_json v = parse
  | "true"      { `Bool true }
  | "false"     { `Bool false }
  | "null"      { `Null }
  | "NaN"       {
                  #ifdef FLOAT
                    `Float nan
                  #elif defined FLOATLIT
                    `Floatlit "NaN"
                  #endif
                }
  | "Infinity"  {
                  #ifdef FLOAT
                    `Float infinity
                  #elif defined FLOATLIT
                    `Floatlit "Infinity"
                  #endif
                }
  | "-Infinity" {
                  #ifdef FLOAT
                    `Float neg_infinity
                  #elif defined FLOATLIT
                    `Floatlit "-Infinity"
                  #endif
                }
  | '"'         {
                  #ifdef STRING
	            Buffer.clear v.buf;
		    `String (finish_string v lexbuf)
                  #elif defined STRINGLIT
                    `Stringlit (finish_stringlit v lexbuf)
                  #endif
                }
  | positive_int         { make_positive_int v lexbuf }
  | '-' positive_int     { make_negative_int v lexbuf }
  | float       {
                  #ifdef FLOAT
                    `Float (float_of_string (lexeme lexbuf))
                  #elif defined FLOATLIT
                    `Floatlit (lexeme lexbuf)
                  #endif
                 }

  | '{'          { let acc = ref [] in
		   try
		     read_space v lexbuf;
		     read_object_end lexbuf;
		     let field_name = read_ident v lexbuf in
		     read_space v lexbuf;
		     read_colon v lexbuf;
		     read_space v lexbuf;
		     acc := (field_name, read_json v lexbuf) :: !acc;
		     while true do
		       read_space v lexbuf;
		       read_object_sep v lexbuf;
		       read_space v lexbuf;
		       let field_name = read_ident v lexbuf in
		       read_space v lexbuf;
		       read_colon v lexbuf;
		       read_space v lexbuf;
		       acc := (field_name, read_json v lexbuf) :: !acc;
		     done;
		     assert false
		   with End_of_object ->
		     `Assoc (List.rev !acc)
		 }

  | '['          { let acc = ref [] in
		   try
		     read_space v lexbuf;
		     read_array_end lexbuf;
		     acc := read_json v lexbuf :: !acc;
		     while true do
		       read_space v lexbuf;
		       read_array_sep v lexbuf;
		       read_space v lexbuf;
		       acc := read_json v lexbuf :: !acc;
		     done;
		     assert false
		   with End_of_array ->
		     `List (List.rev !acc)
		 }

  | '('          {
                   #ifdef TUPLE
                     let acc = ref [] in
		     try
		       read_space v lexbuf;
		       read_tuple_end lexbuf;
		       acc := read_json v lexbuf :: !acc;
		       while true do
			 read_space v lexbuf;
			 read_tuple_sep v lexbuf;
			 read_space v lexbuf;
			 acc := read_json v lexbuf :: !acc;
		       done;
		       assert false
		     with End_of_tuple ->
		       `Tuple (List.rev !acc)
	           #else
		     lexer_error "Invalid token" v lexbuf
                   #endif
		 }

  | '<'          {
                   #ifdef VARIANT
                     read_space v lexbuf;
                     let cons = read_ident v lexbuf in
		     read_space v lexbuf;
		     `Variant (cons, finish_variant v lexbuf)
                   #else
                     lexer_error "Invalid token" v lexbuf
                   #endif
		 }

  | "//"[^'\n']* { read_json v lexbuf }
  | "/*"         { finish_comment v lexbuf; read_json v lexbuf }
  | "\n"         { newline v lexbuf; read_json v lexbuf }
  | space        { read_json v lexbuf }
  | eof          { custom_error "Unexpected end of input" v lexbuf }
  | _            { lexer_error "Invalid token" v lexbuf }


and finish_string v = parse
    '"'           { Buffer.contents v.buf }
  | '\\'          { finish_escaped_char v lexbuf;
		    finish_string v lexbuf }
  | [^ '"' '\\']+ { add_lexeme v.buf lexbuf;
		    finish_string v lexbuf }
  | eof           { custom_error "Unexpected end of input" v lexbuf }

and finish_escaped_char v = parse 
    '"'
  | '\\'
  | '/' as c { Buffer.add_char v.buf c }
  | 'b'  { Buffer.add_char v.buf '\b' }
  | 'f'  { Buffer.add_char v.buf '\012' }
  | 'n'  { Buffer.add_char v.buf '\n' }
  | 'r'  { Buffer.add_char v.buf '\r' }
  | 't'  { Buffer.add_char v.buf '\t' }
  | 'u' (hex as a) (hex as b) (hex as c) (hex as d)
         { utf8_of_bytes v.buf (hex a) (hex b) (hex c) (hex d) }
  | _    { lexer_error "Invalid escape sequence" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }


and finish_stringlit v = parse
    ( '\\' (['"' '\\' '/' 'b' 'f' 'n' 'r' 't'] | 'u' hex hex hex hex)
    | [^'"' '\\'] )* '"'
         { let len = lexbuf.lex_curr_pos - lexbuf.lex_start_pos in
	   let s = String.create (len+1) in
	   s.[0] <- '"';
	   String.blit lexbuf.lex_buffer lexbuf.lex_start_pos s 1 len;
	   s
	 }
  | _    { lexer_error "Invalid string literal" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }

and finish_variant v = parse 
    ':'  { let x = read_json v lexbuf in
	   read_space v lexbuf;
	   close_variant v lexbuf;
	   Some x }
  | '>'  { None }
  | _    { lexer_error "Expected ':' or '>' but found" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }

and close_variant v = parse
    '>'  { () }
  | _    { lexer_error "Expected '>' but found" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }

and finish_comment v = parse
  | "*/" { () }
  | eof  { lexer_error "Unterminated comment" v lexbuf }
  | '\n' { newline v lexbuf; finish_comment v lexbuf }
  | _    { finish_comment v lexbuf }




(* Readers expecting a particular JSON construct *)

and read_eof = parse
    eof       { true }
  | ""        { false }

and read_space v = parse
  | "//"[^'\n']* ('\n'|eof)  { newline v lexbuf; read_space v lexbuf }
  | "/*"                     { finish_comment v lexbuf; read_space v lexbuf }
  | '\n'                     { newline v lexbuf; read_space v lexbuf }
  | [' ' '\t' '\r']+         { read_space v lexbuf }
  | ""                       { () }

and read_null v = parse
    "null"    { () }
  | _         { lexer_error "Expected 'null' but found" v lexbuf }
  | eof       { custom_error "Unexpected end of input" v lexbuf }

and read_bool v = parse
    "true"    { true }
  | "false"   { false }
  | _         { lexer_error "Expected 'true' or 'false' but found" v lexbuf }
  | eof       { custom_error "Unexpected end of input" v lexbuf }

and read_int v = parse
    positive_int         { try extract_positive_int lexbuf
			   with Int_overflow ->
			     lexer_error "Int overflow" v lexbuf }
  | '-' positive_int     { try extract_negative_int lexbuf
			   with Int_overflow ->
			     lexer_error "Int overflow" v lexbuf }
  | _                    { lexer_error "Expected integer but found" v lexbuf }
  | eof                  { custom_error "Unexpected end of input" v lexbuf }

and read_number v = parse
  | "NaN"       { `Float nan }
  | "Infinity"  { `Float infinity }
  | "-Infinity" { `Float neg_infinity }
  | number      { `Float (float_of_string (lexeme lexbuf)) }
  | _           { lexer_error "Expected number but found" v lexbuf }
  | eof         { custom_error "Unexpected end of input" v lexbuf }

and read_string v = parse
    '"'      { Buffer.clear v.buf;
	       finish_string v lexbuf }
  | _        { lexer_error "Expected '\"' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_ident v = parse
    '"'      { Buffer.clear v.buf;
	       finish_string v lexbuf }
  | ident as s
             { s }
  | _        { lexer_error "Expected string or identifier but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_sequence read_cell init_acc v = parse
    '['      { let acc = ref init_acc in
	       try
		 read_space v lexbuf;
		 read_array_end lexbuf;
		 acc := read_cell !acc v lexbuf;
		 while true do
		   read_space v lexbuf;
		   read_array_sep v lexbuf;
		   read_space v lexbuf;
		   acc := read_cell !acc v lexbuf;
		 done;
		 assert false
	       with End_of_array ->
		 !acc
	     }
  | _        { lexer_error "Expected '[' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_list_rev read_cell v = parse
    '['      { let acc = ref [] in
	       try
		 read_space v lexbuf;
		 read_array_end lexbuf;
		 acc := read_cell v lexbuf :: !acc;
		 while true do
		   read_space v lexbuf;
		   read_array_sep v lexbuf;
		   read_space v lexbuf;
		   acc := read_cell v lexbuf :: !acc;
		 done;
		 assert false
	       with End_of_array ->
		 !acc
	     }
  | _        { lexer_error "Expected '[' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_array_end = parse
    ']'      { raise End_of_array }
  | ""       { () }

and read_array_sep v = parse
    ','      { () }
  | ']'      { raise End_of_array }
  | _        { lexer_error "Expected ',' or ']' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }


and read_tuple read_cell init_acc v = parse
    '('          {
                   #ifdef TUPLE
                     let pos = ref 0 in
                     let acc = ref init_acc in
		     try
		       read_space v lexbuf;
		       read_tuple_end lexbuf;
		       acc := read_cell !pos !acc v lexbuf;
		       incr pos;
		       while true do
			 read_space v lexbuf;
			 read_tuple_sep v lexbuf;
			 read_space v lexbuf;
			 acc := read_cell !pos !acc v lexbuf;
			 incr pos;
		       done;
		       assert false
		     with End_of_tuple ->
		       !acc
	           #else
		     lexer_error "Invalid token" v lexbuf
                   #endif
		 }
  | _        { lexer_error "Expected ')' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_tuple_end = parse
    ')'      { raise End_of_tuple }
  | ""       { () }

and read_tuple_sep v = parse
    ','      { () }
  | ')'      { raise End_of_tuple }
  | _        { lexer_error "Expected ',' or ')' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_fields read_field init_acc v = parse
    '{'      { let acc = ref init_acc in
	       try
		 read_space v lexbuf;
		 read_object_end lexbuf;
		 let field_name = read_ident v lexbuf in
		 read_space v lexbuf;
		 read_colon v lexbuf;
		 read_space v lexbuf;
		 acc := read_field !acc field_name v lexbuf;
		 while true do
		   read_space v lexbuf;
		   read_object_sep v lexbuf;
		   read_space v lexbuf;
		   let field_name = read_ident v lexbuf in
		   read_space v lexbuf;
		   read_colon v lexbuf;
		   read_space v lexbuf;
		   acc := read_field !acc field_name v lexbuf;
		 done;
		 assert false
	       with End_of_object ->
		 !acc
	     }
  | _        { lexer_error "Expected '{' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_object_end = parse
    '}'      { raise End_of_object }
  | ""       { () }

and read_object_sep v = parse
    ','      { () }
  | '}'      { raise End_of_object }
  | _        { lexer_error "Expected ',' or '}' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }

and read_colon v = parse
    ':'      { () }
  | _        { lexer_error "Expected ':' but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }


(*** And now pretty much the same thing repeated, 
     only for the purpose of skipping ignored field values ***)

and skip_json v = parse
  | "true"      { () }
  | "false"     { () }
  | "null"      { () }
  | "NaN"       { () }
  | "Infinity"  { () }
  | "-Infinity" { () }
  | '"'         { finish_skip_stringlit v lexbuf }
  | '-'? positive_int     { () }
  | float       { () }

  | '{'          { try
		     read_space v lexbuf;
		     read_object_end lexbuf;
		     skip_ident v lexbuf;
		     read_space v lexbuf;
		     read_colon v lexbuf;
		     read_space v lexbuf;
		     skip_json v lexbuf;
		     while true do
		       read_space v lexbuf;
		       read_object_sep v lexbuf;
		       read_space v lexbuf;
		       skip_ident v lexbuf;
		       read_space v lexbuf;
		       read_colon v lexbuf;
		       read_space v lexbuf;
		       skip_json v lexbuf;
		     done;
		     assert false
		   with End_of_object ->
		     ()
		 }

  | '['          { try
		     read_space v lexbuf;
		     read_array_end lexbuf;
		     skip_json v lexbuf;
		     while true do
		       read_space v lexbuf;
		       read_array_sep v lexbuf;
		       read_space v lexbuf;
		       skip_json v lexbuf;
		     done;
		     assert false
		   with End_of_array ->
		     ()
		 }

  | '('          {
                   #ifdef TUPLE
                     try
		       read_space v lexbuf;
		       read_tuple_end lexbuf;
		       skip_json v lexbuf;
		       while true do
			 read_space v lexbuf;
			 read_tuple_sep v lexbuf;
			 read_space v lexbuf;
			 skip_json v lexbuf;
		       done;
		       assert false
		     with End_of_tuple ->
		       ()
	           #else
		     lexer_error "Invalid token" v lexbuf
                   #endif
		 }

  | '<'          {
                   #ifdef VARIANT
                     read_space v lexbuf;
                     skip_ident v lexbuf;
		     read_space v lexbuf;
		     finish_skip_variant v lexbuf
                   #else
                     lexer_error "Invalid token" v lexbuf
                   #endif
		 }

  | "//"[^'\n']* { skip_json v lexbuf }
  | "/*"         { finish_comment v lexbuf; skip_json v lexbuf }
  | "\n"         { newline v lexbuf; skip_json v lexbuf }
  | space        { skip_json v lexbuf }
  | eof          { custom_error "Unexpected end of input" v lexbuf }
  | _            { lexer_error "Invalid token" v lexbuf }


and finish_skip_stringlit v = parse
    ( '\\' (['"' '\\' '/' 'b' 'f' 'n' 'r' 't'] | 'u' hex hex hex hex)
    | [^'"' '\\'] )* '"'
         { () }
  | _    { lexer_error "Invalid string literal" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }

and finish_skip_variant v = parse 
    ':'  { skip_json v lexbuf;
	   read_space v lexbuf;
	   close_variant v lexbuf }
  | '>'  { () }
  | _    { lexer_error "Expected ':' or '>' but found" v lexbuf }
  | eof  { custom_error "Unexpected end of input" v lexbuf }

and skip_ident v = parse
    '"'      { finish_skip_stringlit v lexbuf }
  | ident    { () }
  | _        { lexer_error "Expected string or identifier but found" v lexbuf }
  | eof      { custom_error "Unexpected end of input" v lexbuf }


{
  let _ = (read_json : lexer_state -> Lexing.lexbuf -> json)

  let read_list read_cell v lexbuf =
    List.rev (read_list_rev read_cell v lexbuf)

  let array_of_rev_list l =
    match l with
	[] -> [| |]
      | x :: tl ->
	  let len = List.length l in
	  let a = Array.make len x in
	  let r = ref tl in
	  for i = len - 2 downto 0 do
	    a.(i) <- List.hd !r;
	    r := List.tl !r
	  done;
	  a

  let read_array read_cell v lexbuf =
    let l = read_list_rev read_cell v lexbuf in
    array_of_rev_list l

  let finish v lexbuf =
    read_space v lexbuf;
    if not (read_eof lexbuf) then
      custom_error "Junk after end of JSON value" v lexbuf

  let init_lexer ?buf ?fname ?(lnum = 1) () =
    let buf =
      match buf with
	  None -> Buffer.create 256
	| Some buf -> buf
    in
    {
      buf = buf;
      lnum = lnum;
      bol = 0;
      fname = fname
    }

  let from_lexbuf v ?(stream = false) lexbuf =
    read_space v lexbuf;

    let x =
      if read_eof lexbuf then
	raise End_of_input
      else
	read_json v lexbuf
    in

    if not stream then
      finish v lexbuf;

    x


  let from_string ?buf ?fname ?lnum s =
    try
      let lexbuf = Lexing.from_string s in
      let v = init_lexer ?buf ?fname ?lnum () in
      from_lexbuf v lexbuf
    with End_of_input ->
      json_error "Blank input data"

  let from_channel ?buf ?fname ?lnum ic =
    try
      let lexbuf = Lexing.from_channel ic in
      let v = init_lexer ?buf ?fname ?lnum () in
      from_lexbuf v lexbuf
    with End_of_input ->
      json_error "Blank input data"

  let from_file ?buf ?fname ?lnum file =
    let ic = open_in file in
    try
      let x = from_channel ?buf ?fname ?lnum ic in
      close_in ic;
      x
    with e ->
      close_in_noerr ic;
      raise e

  let stream_from_lexbuf v ?(fin = fun () -> ()) lexbuf =
    let stream = Some true in
    let f i =
      try Some (from_lexbuf v ?stream lexbuf)
      with
	  End_of_input ->
	    fin ();
	    None
	| e ->
	    (try fin () with _ -> ());
	    raise e
    in
    Stream.from f

  let stream_from_string ?buf ?fname ?lnum s =
    let v = init_lexer ?buf ?fname ?lnum () in
    stream_from_lexbuf v (Lexing.from_string s)

  let stream_from_channel ?buf ?fin ?fname ?lnum ic =
    let lexbuf = Lexing.from_channel ic in
    let v = init_lexer ?buf ?fname ?lnum () in
    stream_from_lexbuf v ?fin lexbuf

  let stream_from_file ?buf ?fname ?lnum file =
    let ic = open_in file in
    let fin () = close_in ic in
    let fname =
      match fname with
	  None -> Some file
	| x -> x
    in
    let lexbuf = Lexing.from_channel ic in
    let v = init_lexer ?buf ?fname ?lnum () in
    stream_from_lexbuf v ~fin lexbuf

  type json_line = [ `Json of json | `Exn of exn ]

  let linestream_from_channel
      ?buf ?(fin = fun () -> ()) ?fname ?lnum:(lnum0 = 1) ic =
    let buf =
      match buf with
	  None -> Some (Buffer.create 256)
	| Some _ -> buf
    in
    let f i =
      try 
	let line = input_line ic in
	let lnum = lnum0 + i in
	Some (`Json (from_string ?buf ?fname ~lnum line))
      with
	  End_of_file -> fin (); None
	| e -> Some (`Exn e)
    in
    Stream.from f

  let linestream_from_file ?buf ?fname ?lnum file =
    let ic = open_in file in
    let fin () = close_in ic in
    let fname =
      match fname with
	  None -> Some file
	| x -> x
    in
    linestream_from_channel ?buf ~fin ?fname ?lnum ic
}