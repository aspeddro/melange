(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

(* When we design a ppx, we should keep it simple, and also think about
   how it would work with other tools like merlin and ocamldep *)

(*
   1. extension point
   {[
     [%bs.raw{| blabla |}]
   ]}
   will be desugared into
   {[
     let module Js =
     struct unsafe_js : string -> 'a end
     in Js.unsafe_js {| blabla |}
   ]}
   The major benefit is to better error reporting (with locations).
   Otherwise

   {[

     let f u = Js.unsafe_js u
     let _ = f (1 + 2)
   ]}
   And if it is inlined some where
*)

let () =
  Ast_derive_projector.init ();
  Ast_derive_js_mapper.init ()

let succeed attr attrs =
  match attrs with
  | [ _ ] -> ()
  | _ ->
      Bs_ast_invariant.mark_used_bs_attribute attr;
      Bs_ast_invariant.warn_discarded_unused_attributes attrs

type mapper = Ast_mapper.mapper

let default_mapper = Ast_mapper.default_mapper
let default_expr_mapper = Ast_mapper.default_mapper.expr

let expr_mapper (self : mapper) (e : Parsetree.expression) =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, loc, Some delim)) ->
      Ast_utf8_string_interp.transform e s loc delim
  (* End rewriting *)
  | Pexp_function cases -> (
      (* {[ function [@bs.exn]
            | Not_found -> 0
            | Invalid_argument -> 1
          ]}*)
      match
        Ast_attributes.process_pexp_fun_attributes_rev e.pexp_attributes
      with
      | false, _ -> default_expr_mapper self e
      | true, pexp_attributes ->
          Ast_bs_open.convertBsErrorFunction e.pexp_loc self pexp_attributes
            cases)
  | Pexp_fun (label, _, pat, body) -> (
      match Ast_attributes.process_attributes_rev e.pexp_attributes with
      | Nothing, _ -> default_expr_mapper self e
      | Uncurry _, pexp_attributes ->
          {
            e with
            pexp_desc =
              Ast_uncurry_gen.to_uncurry_fn e.pexp_loc self label pat body;
            pexp_attributes;
          }
      | Method _, _ ->
          Location.raise_errorf ~loc:e.pexp_loc
            "%@meth is not supported in function expression"
      | Meth_callback _, pexp_attributes ->
          (* FIXME: does it make sense to have a label for [this] ? *)
          {
            e with
            pexp_desc =
              Ast_uncurry_gen.to_method_callback e.pexp_loc self label pat body;
            pexp_attributes;
          })
  | Pexp_apply (fn, args) -> Ast_exp_apply.app_exp_mapper e self fn args
  | Pexp_object { pcstr_self; pcstr_fields } -> (
      match Ast_attributes.process_bs e.pexp_attributes with
      | true, pexp_attributes ->
          {
            e with
            pexp_desc =
              Ast_util.ocaml_obj_as_js_object e.pexp_loc self pcstr_self
                pcstr_fields;
            pexp_attributes;
          }
      | false, _ -> default_expr_mapper self e)
  | Pexp_match
      ( b,
        [
          {
            pc_lhs =
              { ppat_desc = Ppat_construct ({ txt = Lident "true" }, None) };
            pc_guard = None;
            pc_rhs = t_exp;
          };
          {
            pc_lhs =
              { ppat_desc = Ppat_construct ({ txt = Lident "false" }, None) };
            pc_guard = None;
            pc_rhs = f_exp;
          };
        ] )
  | Pexp_match
      ( b,
        [
          {
            pc_lhs =
              { ppat_desc = Ppat_construct ({ txt = Lident "false" }, None) };
            pc_guard = None;
            pc_rhs = f_exp;
          };
          {
            pc_lhs =
              { ppat_desc = Ppat_construct ({ txt = Lident "true" }, None) };
            pc_guard = None;
            pc_rhs = t_exp;
          };
        ] ) ->
      default_expr_mapper self
        { e with pexp_desc = Pexp_ifthenelse (b, t_exp, Some f_exp) }
  | Pexp_let (r, vbs, sub_expr) ->
      {
        e with
        pexp_desc =
          Pexp_let
            ( r,
              Ast_tuple_pattern_flatten.value_bindings_mapper self vbs,
              self.expr self sub_expr );
      }
  | _ -> default_expr_mapper self e

let typ_mapper (self : mapper) (typ : Parsetree.core_type) =
  Ast_core_type_class_type.typ_mapper self typ

let class_type_mapper (self : mapper)
    ({ pcty_attributes; pcty_loc } as ctd : Parsetree.class_type) =
  match Ast_attributes.process_bs pcty_attributes with
  | false, _ -> default_mapper.class_type self ctd
  | true, pcty_attributes -> (
      match ctd.pcty_desc with
      | Pcty_signature { pcsig_self; pcsig_fields } ->
          let pcsig_self = self.typ self pcsig_self in
          {
            ctd with
            pcty_desc =
              Pcty_signature
                {
                  pcsig_self;
                  pcsig_fields =
                    Ast_core_type_class_type.handle_class_type_fields self
                      pcsig_fields;
                };
            pcty_attributes;
          }
      | Pcty_open _ (* let open M in CT *) | Pcty_constr _ | Pcty_extension _
      | Pcty_arrow _ ->
          Location.raise_errorf ~loc:pcty_loc "invalid or unused attribute `bs`"
      )
(* {[class x : int -> object
             end [@bs]
           ]}
           Actually this is not going to happpen as below is an invalid syntax
           {[class type x = int -> object
               end[@bs]]}
*)

let class_expr_mapper (self : mapper) (ce : Parsetree.class_expr) =
  match ce.pcl_desc with
  | Pcl_let (r, vbs, sub_ce) ->
      {
        ce with
        pcl_desc =
          Pcl_let
            ( r,
              Ast_tuple_pattern_flatten.value_bindings_mapper self vbs,
              self.class_expr self sub_ce );
      }
  | _ -> default_mapper.class_expr self ce

let signature_item_mapper (self : mapper) (sigi : Parsetree.signature_item) =
  match sigi.psig_desc with
  | Psig_type (rf, tdcls) -> Ast_tdcls.handleTdclsInSigi self sigi rf tdcls
  | Psig_value ({ pval_attributes; pval_prim } as value_desc) -> (
      let pval_attributes = self.attributes self pval_attributes in
      if Ast_attributes.rs_externals pval_attributes pval_prim then
        Ast_external.handleExternalInSig self value_desc sigi
      else
        match Ast_attributes.has_inline_payload pval_attributes with
        | Some
            ({
               attr_payload =
                 PStr [ { pstr_desc = Pstr_eval ({ pexp_desc }, _) } ];
               _;
             } as attr) -> (
            match pexp_desc with
            | Pexp_constant (Pconst_string (s, _, dec)) ->
                succeed attr pval_attributes;
                {
                  sigi with
                  psig_desc =
                    Psig_value
                      {
                        value_desc with
                        pval_prim =
                          External_ffi_types.inline_string_primitive s dec;
                        pval_attributes = [];
                      };
                }
            | Pexp_constant (Pconst_integer (s, None)) ->
                succeed attr pval_attributes;
                let s = Int32.of_string s in
                {
                  sigi with
                  psig_desc =
                    Psig_value
                      {
                        value_desc with
                        pval_prim = External_ffi_types.inline_int_primitive s;
                        pval_attributes = [];
                      };
                }
            | Pexp_constant (Pconst_integer (s, Some 'L')) ->
                let s = Int64.of_string s in
                succeed attr pval_attributes;
                {
                  sigi with
                  psig_desc =
                    Psig_value
                      {
                        value_desc with
                        pval_prim = External_ffi_types.inline_int64_primitive s;
                        pval_attributes = [];
                      };
                }
            | Pexp_constant (Pconst_float (s, None)) ->
                succeed attr pval_attributes;
                {
                  sigi with
                  psig_desc =
                    Psig_value
                      {
                        value_desc with
                        pval_prim = External_ffi_types.inline_float_primitive s;
                        pval_attributes = [];
                      };
                }
            | Pexp_construct ({ txt = Lident (("true" | "false") as txt) }, None)
              ->
                succeed attr pval_attributes;
                {
                  sigi with
                  psig_desc =
                    Psig_value
                      {
                        value_desc with
                        pval_prim =
                          External_ffi_types.inline_bool_primitive (txt = "true");
                        pval_attributes = [];
                      };
                }
            | _ -> default_mapper.signature_item self sigi)
        | Some _ | None -> default_mapper.signature_item self sigi)
  | _ -> default_mapper.signature_item self sigi

let structure_item_mapper (self : mapper) (str : Parsetree.structure_item) =
  match str.pstr_desc with
  | Pstr_type (rf, tdcls) (* [ {ptype_attributes} as tdcl ] *) ->
      Ast_tdcls.handleTdclsInStru self str rf tdcls
  | Pstr_primitive prim
    when Ast_attributes.rs_externals prim.pval_attributes prim.pval_prim ->
      Ast_external.handleExternalInStru self prim str
  | Pstr_value
      ( Nonrecursive,
        [
          {
            pvb_pat = { ppat_desc = Ppat_var pval_name } as pvb_pat;
            pvb_expr;
            pvb_attributes;
            pvb_loc;
          };
        ] ) -> (
      let pvb_expr = self.expr self pvb_expr in
      let pvb_attributes = self.attributes self pvb_attributes in
      let has_inline_property =
        Ast_attributes.has_inline_payload pvb_attributes
      in
      match (has_inline_property, pvb_expr.pexp_desc) with
      | Some attr, Pexp_constant (Pconst_string (s, _, dec)) ->
          succeed attr pvb_attributes;
          {
            str with
            pstr_desc =
              Pstr_primitive
                {
                  pval_name;
                  pval_type = Ast_literal.type_string ();
                  pval_loc = pvb_loc;
                  pval_attributes = [];
                  pval_prim = External_ffi_types.inline_string_primitive s dec;
                };
          }
      | Some attr, Pexp_constant (Pconst_integer (s, None)) ->
          let s = Int32.of_string s in
          succeed attr pvb_attributes;
          {
            str with
            pstr_desc =
              Pstr_primitive
                {
                  pval_name;
                  pval_type = Ast_literal.type_int ();
                  pval_loc = pvb_loc;
                  pval_attributes = [];
                  pval_prim = External_ffi_types.inline_int_primitive s;
                };
          }
      | Some attr, Pexp_constant (Pconst_integer (s, Some 'L')) ->
          let s = Int64.of_string s in
          succeed attr pvb_attributes;
          {
            str with
            pstr_desc =
              Pstr_primitive
                {
                  pval_name;
                  pval_type = Ast_literal.type_int64;
                  pval_loc = pvb_loc;
                  pval_attributes = [];
                  pval_prim = External_ffi_types.inline_int64_primitive s;
                };
          }
      | Some attr, Pexp_constant (Pconst_float (s, None)) ->
          succeed attr pvb_attributes;
          {
            str with
            pstr_desc =
              Pstr_primitive
                {
                  pval_name;
                  pval_type = Ast_literal.type_float;
                  pval_loc = pvb_loc;
                  pval_attributes = [];
                  pval_prim = External_ffi_types.inline_float_primitive s;
                };
          }
      | ( Some attr,
          Pexp_construct ({ txt = Lident (("true" | "false") as txt) }, None) )
        ->
          succeed attr pvb_attributes;
          {
            str with
            pstr_desc =
              Pstr_primitive
                {
                  pval_name;
                  pval_type = Ast_literal.type_bool ();
                  pval_loc = pvb_loc;
                  pval_attributes = [];
                  pval_prim =
                    External_ffi_types.inline_bool_primitive (txt = "true");
                };
          }
      | _ ->
          {
            str with
            pstr_desc =
              Pstr_value
                ( Nonrecursive,
                  Ast_tuple_pattern_flatten.value_bindings_mapper self
                    [ { pvb_pat; pvb_expr; pvb_attributes; pvb_loc } ] );
          })
  | Pstr_value (r, vbs) ->
      {
        str with
        pstr_desc =
          Pstr_value
            (r, Ast_tuple_pattern_flatten.value_bindings_mapper self vbs);
      }
  | Pstr_attribute { attr_name = { txt = "bs.config" | "config" }; _ } -> str
  | _ -> default_mapper.structure_item self str

let mapper : mapper =
  {
    default_mapper with
    expr = expr_mapper;
    typ = typ_mapper;
    class_type = class_type_mapper;
    class_expr = class_expr_mapper;
    signature_item = signature_item_mapper;
    structure_item = structure_item_mapper;
    (* Ad-hoc way to internalize stuff *)
    label_declaration =
      (fun self lbl ->
        let lbl = default_mapper.label_declaration self lbl in
        match lbl.pld_attributes with
        | [ { attr_name = { txt = "internal" }; _ } ] ->
            {
              lbl with
              pld_name =
                {
                  lbl.pld_name with
                  txt = String.capitalize_ascii lbl.pld_name.txt;
                };
              pld_attributes = [];
            }
        | _ -> lbl);
  }
