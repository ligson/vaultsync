package service

import (
	"archive/zip"
	"encoding/binary"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/ligson/vaultsync/internal/store"
)

func TestIsEncryptedPDFDetectsEncryptionDictionary(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.pdf")
	if err != nil {
		t.Fatalf("create temp PDF: %v", err)
	}
	defer file.Close()
	if _, err := file.WriteString("%PDF-1.7\ntrailer << /Encrypt 12 0 R >>"); err != nil {
		t.Fatalf("write temp PDF: %v", err)
	}
	if encrypted, err := isEncryptedPDF(file); err != nil || !encrypted {
		t.Fatalf("encrypted=%v err=%v, want encrypted PDF", encrypted, err)
	}
}

func TestIsEncryptedPDFAllowsNormalPDF(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.pdf")
	if err != nil {
		t.Fatalf("create temp PDF: %v", err)
	}
	defer file.Close()
	if _, err := file.WriteString("%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj"); err != nil {
		t.Fatalf("write temp PDF: %v", err)
	}
	if encrypted, err := isEncryptedPDF(file); err != nil || encrypted {
		t.Fatalf("encrypted=%v err=%v, want normal PDF", encrypted, err)
	}
}

func TestParseDocumentPreviewExtractsPlainText(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.txt")
	if err != nil {
		t.Fatalf("create temp text file: %v", err)
	}
	defer file.Close()
	if _, err := file.WriteString("第一行\n第二行"); err != nil {
		t.Fatalf("write temp text file: %v", err)
	}
	preview, err := parseDocumentPreview(file, store.DocumentPreviewSource{
		ID: "doc-1", Name: "notes.txt", Format: "txt",
	}, "")
	if err != nil || preview.Kind != "text" || len(preview.Sections) != 1 ||
		preview.Sections[0].Content != "第一行\n第二行" {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}
}

func TestParseDocumentPreviewExtractsEpubChapters(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.epub")
	if err != nil {
		t.Fatalf("create temp EPUB: %v", err)
	}
	defer file.Close()
	archive := zip.NewWriter(file)
	chapter, err := archive.Create("OPS/chapter.xhtml")
	if err != nil {
		t.Fatalf("create EPUB chapter: %v", err)
	}
	if _, err := chapter.Write([]byte("<html><body><h1>第一章</h1><p>正文内容</p></body></html>")); err != nil {
		t.Fatalf("write EPUB chapter: %v", err)
	}
	if err := archive.Close(); err != nil {
		t.Fatalf("close EPUB: %v", err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		t.Fatalf("rewind EPUB: %v", err)
	}
	preview, err := parseDocumentPreview(file, store.DocumentPreviewSource{
		ID: "doc-2", Name: "book.epub", Format: "epub",
	}, "")
	if err != nil || preview.Kind != "book" || len(preview.Sections) != 1 ||
		!strings.Contains(preview.Sections[0].Content, "第一章") {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}
}

func TestParseDocumentPreviewUsesEpubSpineOrder(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.epub")
	if err != nil {
		t.Fatalf("create temp EPUB: %v", err)
	}
	defer file.Close()
	archive := zip.NewWriter(file)
	container, err := archive.Create("META-INF/container.xml")
	if err != nil {
		t.Fatalf("create EPUB container: %v", err)
	}
	_, _ = container.Write([]byte(`<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>`))
	opf, err := archive.Create("OPS/package.opf")
	if err != nil {
		t.Fatalf("create EPUB package: %v", err)
	}
	_, _ = opf.Write([]byte(`<?xml version="1.0"?><package><manifest><item id="second" href="second.xhtml"/><item id="first" href="first.xhtml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>`))
	second, err := archive.Create("OPS/second.xhtml")
	if err != nil {
		t.Fatalf("create second chapter: %v", err)
	}
	_, _ = second.Write([]byte(`<html><body><h1>第二章</h1><p>内容二</p></body></html>`))
	first, err := archive.Create("OPS/first.xhtml")
	if err != nil {
		t.Fatalf("create first chapter: %v", err)
	}
	_, _ = first.Write([]byte(`<html><body><h1>第一章</h1><p>内容一</p></body></html>`))
	if err := archive.Close(); err != nil {
		t.Fatalf("close EPUB: %v", err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		t.Fatalf("rewind EPUB: %v", err)
	}
	preview, err := parseDocumentPreview(file, store.DocumentPreviewSource{
		ID: "doc-spine", Name: "book.epub", Format: "epub",
	}, "")
	if err != nil || len(preview.Sections) != 2 ||
		!strings.Contains(preview.Sections[0].Content, "第一章") ||
		!strings.Contains(preview.Sections[1].Content, "第二章") ||
		preview.Sections[0].Title != "第一章" || preview.Sections[1].Title != "第二章" {
		t.Fatalf("preview=%#v err=%v, want spine order", preview, err)
	}
}

func TestParseDocumentPreviewRejectsEncryptedSource(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.txt")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer file.Close()
	_, _ = file.WriteString("secret")
	_, err = parseDocumentPreview(file, store.DocumentPreviewSource{
		ID: "doc-3", Name: "secret.txt", Format: "txt", EncryptionEnabled: true,
	}, "")
	if err == nil {
		t.Fatal("encrypted source was accepted for online preview")
	}
	if _, ok := err.(AppError); !ok {
		t.Fatalf("error=%T %v, want AppError", err, err)
	}
}

func TestMobiTextExtractsPlainPalmDOC(t *testing.T) {
	content := []byte("MOBI plain text\n第二行")
	const recordCount = 2
	const firstRecord = 78 + recordCount*8
	const mobiHeaderLength = 0x98
	const firstRecordLength = 16 + mobiHeaderLength
	textRecord := firstRecord + firstRecordLength
	data := make([]byte, textRecord+len(content))
	copy(data[60:68], []byte("BOOKMOBI"))
	binary.BigEndian.PutUint16(data[76:78], recordCount)
	binary.BigEndian.PutUint32(data[78:82], firstRecord)
	binary.BigEndian.PutUint32(data[86:90], uint32(textRecord))

	// PalmDOC header at the beginning of the first record.
	binary.BigEndian.PutUint16(data[firstRecord:firstRecord+2], 1) // no compression
	binary.BigEndian.PutUint32(data[firstRecord+4:firstRecord+8], uint32(len(content)))
	binary.BigEndian.PutUint16(data[firstRecord+8:firstRecord+10], 1)
	binary.BigEndian.PutUint16(data[firstRecord+10:firstRecord+12], 4096)
	copy(data[firstRecord+16:firstRecord+20], []byte("MOBI"))
	binary.BigEndian.PutUint32(data[firstRecord+20:firstRecord+24], mobiHeaderLength)
	binary.BigEndian.PutUint32(data[firstRecord+16+0x88:firstRecord+16+0x8c], 0xffffffff)
	binary.BigEndian.PutUint32(data[firstRecord+16+0x8c:firstRecord+16+0x90], 0)
	copy(data[textRecord:], content)

	decoded, err := mobiText(data)
	if err != nil {
		t.Fatalf("mobiText returned error: %v", err)
	}
	if decoded != string(content) {
		t.Fatalf("decoded=%q, want %q", decoded, content)
	}
}

func TestReadTextChunkKeepsPagesSmallAndValidUTF8(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "document-*.txt")
	if err != nil {
		t.Fatalf("create temp text file: %v", err)
	}
	defer file.Close()
	content := strings.Repeat("你好，VaultSync。\n", 5000)
	if _, err := file.WriteString(content); err != nil {
		t.Fatalf("write temp text file: %v", err)
	}

	page, actualOffset, nextOffset, hasMore, err := readTextChunk(file, 1, 64)
	if err != nil {
		t.Fatalf("read first page: %v", err)
	}
	if actualOffset != 0 || len([]byte(page)) > 64 || !utf8.ValidString(page) {
		t.Fatalf("page=%q offset=%d bytes=%d valid=%v", page, actualOffset, len([]byte(page)), utf8.ValidString(page))
	}
	if !hasMore || nextOffset <= actualOffset {
		t.Fatalf("nextOffset=%d hasMore=%v, want another page", nextOffset, hasMore)
	}

	nextPage, nextActualOffset, _, _, err := readTextChunk(file, nextOffset, 64)
	if err != nil {
		t.Fatalf("read second page: %v", err)
	}
	if nextActualOffset != nextOffset || !utf8.ValidString(nextPage) {
		t.Fatalf("second page offset=%d expected=%d valid=%v", nextActualOffset, nextOffset, utf8.ValidString(nextPage))
	}
}

func TestTextChunkAlignsOffsetToRuneStart(t *testing.T) {
	content := "你好，世界"
	page, actualOffset, nextOffset, hasMore := textChunk(content, 1, 4)
	if actualOffset != 0 || page != "你" || nextOffset != int64(len([]byte("你"))) || !hasMore {
		t.Fatalf("page=%q offset=%d next=%d hasMore=%v", page, actualOffset, nextOffset, hasMore)
	}
}
