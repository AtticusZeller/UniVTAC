# Header-only library. GitHub regenerated the v2.9.3 archive without changing the tag.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO syoyo/tinygltf
    REF "v${VERSION}"
    SHA512 6dbcff3ea602d0aa45ddd87a87d32ab5ab5453901891dbccfbc660746fe11c5bd814d6f74707244351dd6326e17f6d9ad7c384417db126122cc4a2cba20b205c
    HEAD_REF master
)

vcpkg_replace_string("${SOURCE_PATH}/tiny_gltf.h" "#include \"json.hpp\"" "#include <nlohmann/json.hpp>")
file(INSTALL "${SOURCE_PATH}/tiny_gltf.h" DESTINATION "${CURRENT_PACKAGES_DIR}/include")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
