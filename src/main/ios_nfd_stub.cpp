// iOS has no native file dialog (nativefiledialog-extended needs AppKit/GTK).
// These no-op stubs satisfy the NFD calls made by main.cpp and RecompFrontend.
#include "nfd.h"

nfdresult_t NFD_Init(void) { return NFD_OKAY; }
void NFD_Quit(void) {}
void NFD_FreePathN(nfdnchar_t *) {}
nfdresult_t NFD_OpenDialogN(nfdnchar_t **outPath, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    if (outPath != nullptr) {
        *outPath = nullptr;
    }
    return NFD_CANCEL;
}
nfdresult_t NFD_OpenDialogMultipleN(const nfdpathset_t **outPaths, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    if (outPaths != nullptr) {
        *outPaths = nullptr;
    }
    return NFD_CANCEL;
}
nfdresult_t NFD_PathSet_GetCount(const nfdpathset_t *, nfdpathsetsize_t *count) {
    if (count != nullptr) {
        *count = 0;
    }
    return NFD_ERROR;
}
nfdresult_t NFD_PathSet_GetPathN(const nfdpathset_t *, nfdpathsetsize_t, nfdnchar_t **outPath) {
    if (outPath != nullptr) {
        *outPath = nullptr;
    }
    return NFD_ERROR;
}
void NFD_PathSet_Free(const nfdpathset_t *) {}
