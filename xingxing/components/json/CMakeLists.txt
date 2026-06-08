# IDF v6 moved the old built-in `json` component to the managed component
# `espressif/cjson`, whose component name is `cjson`. Some upstream managed
# components still declare `REQUIRES json`; keep this tiny local alias so those
# transitive requirements resolve without patching vendor code.
idf_component_register(REQUIRES cjson)
