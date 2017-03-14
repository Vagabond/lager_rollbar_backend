.PHONY: rel stagedevrel deps test

all: compile

compile:
	./rebar3 compile

clean:
	./rebar3 clean

test:
	./rebar3 eunit


dialyzer:
	./rebar3 dialyzer

xref:
	./rebar3 xref
