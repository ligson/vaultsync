package service

import "testing"

func TestValidDocumentFormatIncludesCommonOfficeVariants(t *testing.T) {
	for _, format := range []string{"docm", "dotx", "xlsm", "xltx", "pptm", "potx"} {
		if !validDocumentFormat("office", format) {
			t.Errorf("office format %q should be accepted", format)
		}
	}
}

func TestValidDocumentFormatRejectsUnknownExtension(t *testing.T) {
	if validDocumentFormat("pdf", "docx") || validDocumentFormat("text", "exe") {
		t.Fatal("format accepted for the wrong document type")
	}
}
