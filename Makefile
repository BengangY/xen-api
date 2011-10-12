PACKS=lwt,lwt.syntax,lwt.unix,stdext
OBJS=helpers iteratees lwt_support test wsproxy
OCAMLC=ocamlc
OCAMLOPT=ocamlopt
OCAMLFIND=ocamlfind
OCAMLCFLAGS=-package $(PACKS) -syntax camlp4o 
OCAMLOPTFLAGS=-package $(PACKS) -syntax camlp4o -annot
OCAMLLINKFLAGS=-package $(PACKS) -linkpkg

wsproxy : $(foreach obj,$(OBJS),$(obj).cmx)
	$(OCAMLFIND) $(OCAMLOPT) $(OCAMLLINKFLAGS) $^ -o wsproxy

%.cmo: %.ml %.cmi
	$(OCAMLFIND) $(OCAMLC) $(OCAMLCFLAGS) -c -o $@ $<

%.cmi: %.mli
	$(OCAMLFIND) $(OCAMLC) $(OCAMLCFLAGS) -c -o $@ $<

%.cmx: %.ml %.cmi
	$(OCAMLFIND) $(OCAMLOPT) $(OCAMLOPTFLAGS) $(RPCLIGHTFLAGS) -c -thread -I ../rpc-light -I ../stdext -I ../log -I ../stunnel -o $@ $<

.PHONY: clean
clean:
	rm -f *.annot *.o *~ *.cmi *.cmx *.cmo wsproxy

helpers.cmo: helpers.cmi
helpers.cmx: helpers.cmi
iteratees.cmo: helpers.cmi iteratees.cmi
iteratees.cmx: helpers.cmx iteratees.cmi
lwt_support.cmo: iteratees.cmi lwt_support.cmi
lwt_support.cmx: iteratees.cmx lwt_support.cmi
wsproxy.cmo: lwt_support.cmi iteratees.cmi helpers.cmi wsproxy.cmi
wsproxy.cmx: lwt_support.cmx iteratees.cmx helpers.cmx wsproxy.cmi
helpers.cmi:
iteratees.cmi:
lwt_support.cmi: iteratees.cmi
test.cmi:
wsproxy.cmi:




