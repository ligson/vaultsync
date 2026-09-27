package service

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/ligson/vaultsync/internal/domain"
	"github.com/ligson/vaultsync/internal/store"
)

const (
	maxPreviewTextBytes     = 2 * 1024 * 1024
	maxPreviewSections      = 200
	maxPreviewChars         = 2_000_000
	defaultPreviewPageBytes = 16 * 1024
	maxPreviewPageBytes     = 64 * 1024
)

func parseDocumentPreviewMetadata(file *os.File, source store.DocumentPreviewSource) (domain.DocumentPreview, error) {
	preview := newDocumentPreview(source)
	preview.Paged = source.Format != "pdf"
	preview.TotalBytes = source.SizeBytes
	if source.Format == "pdf" {
		return preview, nil
	}
	var sections []domain.DocumentPreviewSection
	switch source.Format {
	case "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml", "log":
		sections = []domain.DocumentPreviewSection{{ID: "main", Title: "正文"}}
	case "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "pptx", "pptm", "potx", "potm", "odt", "ods", "odp", "epub":
		info, statErr := file.Stat()
		if statErr != nil {
			return domain.DocumentPreview{}, statErr
		}
		archive, zipErr := zip.NewReader(file, info.Size())
		if zipErr != nil {
			return domain.DocumentPreview{}, zipErr
		}
		if source.Format == "epub" {
			sections = epubSectionDescriptors(archive)
		} else {
			for _, sectionID := range officeContentPaths(archive, source.Format) {
				sections = append(sections, domain.DocumentPreviewSection{
					ID: sectionID, Title: officeSectionTitle(sectionID, source.Format),
				})
			}
		}
	case "fb2":
		sections = []domain.DocumentPreviewSection{{ID: "body", Title: "正文"}}
	case "mobi":
		sections = []domain.DocumentPreviewSection{{ID: "body", Title: "正文"}}
	default:
		return domain.DocumentPreview{}, InvalidRequest("此格式暂不支持在线预览，请下载原文件")
	}
	if len(sections) == 0 {
		return domain.DocumentPreview{}, InvalidRequest("文档没有可显示的内容")
	}
	preview.Sections = sections
	return preview, nil
}

func parseDocumentPreviewPage(file *os.File, source store.DocumentPreviewSource, sectionID string, offset int64, limit int) (domain.DocumentPreview, error) {
	preview := newDocumentPreview(source)
	preview.Paged = true
	preview.TotalBytes = source.SizeBytes
	if source.Format == "pdf" {
		return preview, nil
	}
	if sectionID == "" {
		sectionID = "main"
	}
	var content string
	var actualOffset, nextOffset int64
	var hasMore bool
	var err error
	switch source.Format {
	case "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml", "log":
		if sectionID != "main" {
			return domain.DocumentPreview{}, InvalidRequest("文档章节不存在")
		}
		content, actualOffset, nextOffset, hasMore, err = readTextChunk(file, offset, limit)
	case "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "pptx", "pptm", "potx", "potm", "odt", "ods", "odp", "epub":
		content, err = zipSectionContent(file, source.Format, sectionID)
		if err == nil {
			content, actualOffset, nextOffset, hasMore = textChunk(content, offset, limit)
		}
	case "fb2":
		data, readErr := io.ReadAll(io.LimitReader(file, maxPreviewSourceBytes+1))
		if readErr == nil {
			content, actualOffset, nextOffset, hasMore = textChunk(xmlText(data), offset, limit)
		} else {
			err = readErr
		}
	case "mobi":
		data, readErr := io.ReadAll(io.LimitReader(file, maxPreviewSourceBytes+1))
		if readErr == nil {
			decoded, decodeErr := mobiText(data)
			if decodeErr != nil {
				err = decodeErr
			} else {
				content, actualOffset, nextOffset, hasMore = textChunk(decoded, offset, limit)
			}
		} else {
			err = readErr
		}
	default:
		return domain.DocumentPreview{}, InvalidRequest("此格式暂不支持在线预览，请下载原文件")
	}
	if err != nil {
		return domain.DocumentPreview{}, InvalidRequest("文档内容无法解析，请下载原文件查看")
	}
	preview.SectionID = sectionID
	preview.Offset = actualOffset
	preview.NextOffset = nextOffset
	preview.HasMore = hasMore
	preview.Sections = []domain.DocumentPreviewSection{{
		ID: sectionID, Title: sectionID, Content: content,
	}}
	return preview, nil
}

func newDocumentPreview(source store.DocumentPreviewSource) domain.DocumentPreview {
	name := source.Name
	if payload := plainMetadataName(source.MetadataJSON); payload != "" {
		name = payload
	}
	return domain.DocumentPreview{
		ID: source.ID, Name: name, Format: source.Format,
		Kind: previewKind(source.Format), EncryptionEnabled: source.EncryptionEnabled,
		Sections: []domain.DocumentPreviewSection{},
	}
}

func readTextChunk(file *os.File, offset int64, limit int) (string, int64, int64, bool, error) {
	info, err := file.Stat()
	if err != nil {
		return "", 0, 0, false, err
	}
	if limit <= 0 {
		limit = defaultPreviewPageBytes
	}
	if offset > info.Size() {
		offset = info.Size()
	}
	// Page offsets are normally produced at UTF-8 boundaries. Align malformed
	// or externally supplied offsets backwards so a multibyte character is not
	// lost when a caller resumes from the middle of a rune.
	for offset > 0 {
		var byteAt [1]byte
		if _, readErr := file.ReadAt(byteAt[:], offset); readErr != nil {
			break
		}
		if byteAt[0]&0xc0 != 0x80 {
			break
		}
		offset--
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return "", 0, 0, false, err
	}
	data, err := io.ReadAll(io.LimitReader(file, int64(limit)+4))
	if err != nil {
		return "", 0, 0, false, err
	}
	if len(data) > limit {
		data = data[:limit]
	}
	for len(data) > 0 && !utf8.Valid(data) {
		data = data[:len(data)-1]
	}
	end := offset + int64(len(data))
	return string(data), offset, end, end < info.Size(), nil
}

func textChunk(content string, offset int64, limit int) (string, int64, int64, bool) {
	data := []byte(content)
	if offset < 0 {
		offset = 0
	}
	if offset > int64(len(data)) {
		offset = int64(len(data))
	}
	start := int(offset)
	for start < len(data) && start > 0 && data[start]&0xc0 == 0x80 {
		start--
	}
	end := start + limit
	if end > len(data) {
		end = len(data)
	}
	for end > start && !utf8.Valid(data[start:end]) {
		end--
	}
	return string(data[start:end]), int64(start), int64(end), end < len(data)
}

func zipSectionContent(file *os.File, format, sectionID string) (string, error) {
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	archive, err := zip.NewReader(file, info.Size())
	if err != nil {
		return "", err
	}
	entry := findZipEntry(archive, sectionID)
	if entry == nil {
		return "", fmt.Errorf("section %q not found", sectionID)
	}
	data, err := readZipEntry(entry, maxPreviewTextBytes)
	if err != nil {
		return "", err
	}
	return xmlText(data), nil
}

func epubSectionDescriptors(archive *zip.Reader) []domain.DocumentPreviewSection {
	paths, ok := epubSpinePaths(archive)
	if !ok {
		paths = make([]string, 0)
		for _, entry := range archive.File {
			lower := strings.ToLower(entry.Name)
			if strings.HasSuffix(lower, ".xhtml") || strings.HasSuffix(lower, ".html") || strings.HasSuffix(lower, ".htm") {
				paths = append(paths, entry.Name)
			}
		}
		sort.Strings(paths)
	}
	sections := make([]domain.DocumentPreviewSection, 0, len(paths))
	for _, sectionID := range paths {
		title := strings.TrimSuffix(path.Base(sectionID), path.Ext(sectionID))
		if entry := findZipEntry(archive, sectionID); entry != nil {
			if data, err := readZipEntry(entry, 128*1024); err == nil {
				title = epubSectionTitle(data, sectionID)
			}
		}
		sections = append(sections, domain.DocumentPreviewSection{ID: sectionID, Title: title})
	}
	return sections
}

func parseDocumentPreview(file *os.File, source store.DocumentPreviewSource, _ string) (domain.DocumentPreview, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return domain.DocumentPreview{}, err
	}
	name := source.Name
	if payload := plainMetadataName(source.MetadataJSON); payload != "" {
		name = payload
	}
	preview := domain.DocumentPreview{
		ID: source.ID, Name: name, Format: source.Format,
		Kind: previewKind(source.Format), EncryptionEnabled: source.EncryptionEnabled,
		Sections: []domain.DocumentPreviewSection{},
	}
	if source.EncryptionEnabled {
		return domain.DocumentPreview{}, Forbidden("为保护数据安全，加密文档不能在线预览，请下载后查看")
	}
	if source.Format == "pdf" {
		if encrypted, err := isEncryptedPDF(file); err != nil {
			return domain.DocumentPreview{}, InvalidRequest("PDF 内容无法读取，请下载原文件查看")
		} else if encrypted {
			return domain.DocumentPreview{}, Forbidden("为保护数据安全，带密码的 PDF 不能在线预览，请下载后查看")
		}
		return preview, nil
	}
	var sections []domain.DocumentPreviewSection
	var truncated bool
	var err error
	switch source.Format {
	case "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml", "log":
		sections, truncated, err = textSections(file)
	case "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "pptx", "pptm", "potx", "potm", "odt", "ods", "odp", "epub":
		sections, truncated, err = zipDocumentSections(file, source.Format)
	case "fb2":
		sections, truncated, err = fb2Sections(file)
	case "mobi":
		data, readErr := io.ReadAll(io.LimitReader(file, maxPreviewTextBytes+1))
		if readErr != nil {
			err = readErr
		} else {
			var content string
			content, err = mobiText(data)
			if err == nil {
				content = trimPreview(content)
				sections = []domain.DocumentPreviewSection{{ID: "body", Title: "正文", Content: content}}
				truncated = len(data) > maxPreviewTextBytes
			}
		}
	default:
		return domain.DocumentPreview{}, InvalidRequest("此格式暂不支持在线预览，请下载原文件")
	}
	if err != nil {
		return domain.DocumentPreview{}, InvalidRequest("文档内容无法解析，请下载原文件查看")
	}
	preview.Sections = sections
	preview.Truncated = truncated
	return preview, nil
}

func isEncryptedPDF(file *os.File) (bool, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return false, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maxPreviewSourceBytes))
	if err != nil {
		return false, err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return false, err
	}
	return bytes.Contains(data, []byte("/Encrypt")), nil
}

func plainMetadataName(metadata string) string {
	var payload map[string]any
	if json.Unmarshal([]byte(metadata), &payload) != nil || payload["format"] != "vaultsync-metadata-plain-v1" {
		return ""
	}
	name, _ := payload["name"].(string)
	return strings.TrimSpace(name)
}

func previewKind(format string) string {
	switch format {
	case "pdf":
		return "pdf"
	case "epub", "fb2", "mobi":
		return "book"
	default:
		return "text"
	}
}

// mobiText supports the common unencrypted PalmDOC MOBI layout. KF8/AZW3,
// Huff/CDIC and DRM variants remain download-only until a dedicated parser is added.
func mobiText(data []byte) (string, error) {
	if len(data) < 78 || string(data[60:68]) != "BOOKMOBI" && string(data[60:68]) != "TEXtREAd" {
		return "", fmt.Errorf("not a Palm database")
	}
	recordCount := int(binary.BigEndian.Uint16(data[76:78]))
	if recordCount < 2 || len(data) < 78+recordCount*8 {
		return "", fmt.Errorf("invalid MOBI records")
	}
	firstRecord := int(binary.BigEndian.Uint32(data[78:82]))
	if firstRecord+16 > len(data) || string(data[firstRecord+16:firstRecord+20]) != "MOBI" {
		return "", fmt.Errorf("unsupported MOBI header")
	}
	mobiHeaderLength := int(binary.BigEndian.Uint32(data[firstRecord+20 : firstRecord+24]))
	if mobiHeaderLength < 0x98 || firstRecord+16+mobiHeaderLength > len(data) {
		return "", fmt.Errorf("invalid MOBI header")
	}
	drmOffset := binary.BigEndian.Uint32(data[firstRecord+16+0x88 : firstRecord+16+0x8c])
	drmCount := binary.BigEndian.Uint32(data[firstRecord+16+0x8c : firstRecord+16+0x90])
	if drmOffset != 0xffffffff || drmCount != 0 {
		return "", fmt.Errorf("encrypted MOBI is not supported")
	}
	compression := binary.BigEndian.Uint16(data[firstRecord : firstRecord+2])
	textLength := int(binary.BigEndian.Uint32(data[firstRecord+4 : firstRecord+8]))
	textRecords := int(binary.BigEndian.Uint16(data[firstRecord+8 : firstRecord+10]))
	recordSize := int(binary.BigEndian.Uint16(data[firstRecord+10 : firstRecord+12]))
	if compression != 1 && compression != 2 {
		return "", fmt.Errorf("unsupported MOBI compression")
	}
	if recordSize <= 0 || textRecords <= 0 || textRecords > recordCount-1 {
		return "", fmt.Errorf("invalid MOBI text records")
	}
	var out bytes.Buffer
	for i := 0; i < textRecords; i++ {
		start := int(binary.BigEndian.Uint32(data[78+(i+1)*8 : 78+(i+1)*8+4]))
		end := len(data)
		if i+1 < textRecords {
			end = int(binary.BigEndian.Uint32(data[78+(i+2)*8 : 78+(i+2)*8+4]))
		}
		if start < 0 || end < start || end > len(data) {
			return "", fmt.Errorf("invalid MOBI text record")
		}
		if compression == 1 {
			_, _ = out.Write(data[start:end])
		} else {
			decoded, err := decompressPalmDOC(data[start:end])
			if err != nil {
				return "", err
			}
			_, _ = out.Write(decoded)
		}
	}
	content := out.Bytes()
	if textLength > 0 && textLength < len(content) {
		content = content[:textLength]
	}
	return strings.TrimSpace(string(content)), nil
}

func decompressPalmDOC(data []byte) ([]byte, error) {
	out := make([]byte, 0, len(data)*2)
	for i := 0; i < len(data); i++ {
		value := data[i]
		switch {
		case value >= 0x01 && value <= 0x08:
			count := int(value)
			if i+count >= len(data) {
				return nil, fmt.Errorf("invalid PalmDOC literal")
			}
			out = append(out, data[i+1:i+count+1]...)
			i += count
		case value >= 0x09 && value <= 0x7f:
			out = append(out, value)
		case value >= 0x80 && value <= 0xbf:
			if i+1 >= len(data) {
				return nil, fmt.Errorf("invalid PalmDOC copy")
			}
			pair := uint16(value)<<8 | uint16(data[i+1])
			distance := int((pair & 0x3fff) >> 3)
			length := int(pair&7) + 3
			if distance == 0 || distance > len(out) {
				return nil, fmt.Errorf("invalid PalmDOC distance")
			}
			for n := 0; n < length; n++ {
				out = append(out, out[len(out)-distance])
			}
			i++
		case value >= 0xc0:
			out = append(out, ' ', value&0x7f)
		default:
			out = append(out, value)
		}
	}
	return out, nil
}

func previewContentType(format string) string {
	switch format {
	case "pdf":
		return "application/pdf"
	case "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "rtf":
		return "text/plain; charset=utf-8"
	default:
		return "application/octet-stream"
	}
}

func textSections(file *os.File) ([]domain.DocumentPreviewSection, bool, error) {
	data, err := io.ReadAll(io.LimitReader(file, maxPreviewTextBytes+1))
	if err != nil {
		return nil, false, err
	}
	truncated := len(data) > maxPreviewTextBytes
	if truncated {
		data = data[:maxPreviewTextBytes]
	}
	content := strings.TrimSpace(string(data))
	return []domain.DocumentPreviewSection{{ID: "main", Title: "正文", Content: content}}, truncated, nil
}

func zipDocumentSections(file *os.File, format string) ([]domain.DocumentPreviewSection, bool, error) {
	info, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	archive, err := zip.NewReader(file, info.Size())
	if err != nil {
		return nil, false, err
	}
	if format == "epub" {
		return epubSections(archive)
	}
	paths := officeContentPaths(archive, format)
	if len(paths) == 0 {
		return nil, false, fmt.Errorf("zip document contains no readable content")
	}
	var sections []domain.DocumentPreviewSection
	truncated := false
	totalBytes := 0
	for _, path := range paths {
		if len(sections) >= maxPreviewSections {
			truncated = true
			break
		}
		entry := findZipEntry(archive, path)
		if entry == nil {
			continue
		}
		reader, openErr := entry.Open()
		if openErr != nil {
			return nil, false, openErr
		}
		data, readErr := io.ReadAll(io.LimitReader(reader, maxPreviewTextBytes))
		_ = reader.Close()
		if readErr != nil {
			return nil, false, readErr
		}
		content := xmlText(data)
		if strings.TrimSpace(content) == "" {
			continue
		}
		content, contentTruncated := trimPreviewTo(content, maxPreviewChars-totalBytes)
		sections = append(sections, domain.DocumentPreviewSection{
			ID: path, Title: officeSectionTitle(path, format), Content: content,
		})
		totalBytes += len(content)
		if contentTruncated || totalBytes >= maxPreviewChars {
			truncated = true
			break
		}
	}
	if len(sections) == 0 {
		return nil, false, fmt.Errorf("zip document contains no readable XML")
	}
	return sections, truncated, nil
}

func officeContentPaths(archive *zip.Reader, format string) []string {
	paths := make([]string, 0)
	for _, entry := range archive.File {
		lower := strings.ToLower(entry.Name)
		include := false
		switch format {
		case "docx", "docm", "dotx", "dotm":
			include = lower == "word/document.xml" || lower == "word/footnotes.xml" || lower == "word/endnotes.xml"
		case "xlsx", "xlsm", "xltx", "xltm":
			include = lower == "xl/sharedstrings.xml" || strings.HasPrefix(lower, "xl/worksheets/sheet") && strings.HasSuffix(lower, ".xml")
		case "pptx", "pptm", "potx", "potm":
			include = strings.HasPrefix(lower, "ppt/slides/slide") && strings.HasSuffix(lower, ".xml")
		case "odt", "ods", "odp":
			include = lower == "content.xml"
		}
		if include {
			paths = append(paths, entry.Name)
		}
	}
	sort.Strings(paths)
	return paths
}

func officeSectionTitle(path, format string) string {
	name := strings.TrimSuffix(path[strings.LastIndex(path, "/")+1:], ".xml")
	switch format {
	case "docx", "docm", "dotx", "dotm":
		if name == "document" {
			return "正文"
		}
	case "xlsx", "xlsm", "xltx", "xltm":
		if name == "sharedStrings" {
			return "共享文本"
		}
		return strings.Replace(name, "sheet", "工作表 ", 1)
	case "pptx", "pptm", "potx", "potm":
		return strings.Replace(name, "slide", "幻灯片 ", 1)
	case "odt", "ods", "odp":
		return "正文"
	}
	return name
}

func epubSections(archive *zip.Reader) ([]domain.DocumentPreviewSection, bool, error) {
	if paths, ok := epubSpinePaths(archive); ok {
		sections, truncated := readEpubSections(archive, paths)
		if len(sections) > 0 {
			return sections, truncated, nil
		}
	}

	paths := make([]string, 0)
	for _, entry := range archive.File {
		lower := strings.ToLower(entry.Name)
		if strings.HasSuffix(lower, ".xhtml") || strings.HasSuffix(lower, ".html") || strings.HasSuffix(lower, ".htm") {
			paths = append(paths, entry.Name)
		}
	}
	sort.Strings(paths)
	sections, truncated := readEpubSections(archive, paths)
	return sections, truncated, nil
}

type epubContainerDocument struct {
	Rootfiles struct {
		Rootfiles []struct {
			FullPath string `xml:"full-path,attr"`
		} `xml:"rootfile"`
	} `xml:"rootfiles"`
}

type epubPackageDocument struct {
	Manifest struct {
		Items []struct {
			ID        string `xml:"id,attr"`
			Href      string `xml:"href,attr"`
			MediaType string `xml:"media-type,attr"`
		} `xml:"item"`
	} `xml:"manifest"`
	Spine struct {
		ItemRefs []struct {
			IDRef string `xml:"idref,attr"`
		} `xml:"itemref"`
	} `xml:"spine"`
}

func epubSpinePaths(archive *zip.Reader) ([]string, bool) {
	containerEntry := findZipEntry(archive, "META-INF/container.xml")
	if containerEntry == nil {
		return nil, false
	}
	containerData, err := readZipEntry(containerEntry, 128*1024)
	if err != nil {
		return nil, false
	}
	var container epubContainerDocument
	if err := xml.Unmarshal(containerData, &container); err != nil ||
		len(container.Rootfiles.Rootfiles) == 0 {
		return nil, false
	}
	opfPath := strings.TrimSpace(container.Rootfiles.Rootfiles[0].FullPath)
	if opfPath == "" {
		return nil, false
	}
	opfEntry := findZipEntry(archive, opfPath)
	if opfEntry == nil {
		return nil, false
	}
	opfData, err := readZipEntry(opfEntry, maxPreviewTextBytes)
	if err != nil {
		return nil, false
	}
	var packageDoc epubPackageDocument
	if err := xml.Unmarshal(opfData, &packageDoc); err != nil {
		return nil, false
	}
	manifest := make(map[string]string, len(packageDoc.Manifest.Items))
	base := path.Dir(opfPath)
	for _, item := range packageDoc.Manifest.Items {
		if item.ID == "" || item.Href == "" {
			continue
		}
		href := strings.SplitN(item.Href, "#", 2)[0]
		if decoded, err := url.PathUnescape(href); err == nil {
			href = decoded
		}
		resolved := path.Clean(path.Join(base, href))
		manifest[item.ID] = strings.TrimPrefix(resolved, "/")
	}
	paths := make([]string, 0, len(packageDoc.Spine.ItemRefs))
	for _, itemRef := range packageDoc.Spine.ItemRefs {
		if resolved := manifest[itemRef.IDRef]; resolved != "" {
			paths = append(paths, resolved)
		}
	}
	return paths, len(paths) > 0
}

func readEpubSections(archive *zip.Reader, paths []string) ([]domain.DocumentPreviewSection, bool) {
	sections := make([]domain.DocumentPreviewSection, 0, len(paths))
	totalBytes := 0
	for _, path := range paths {
		if len(sections) >= maxPreviewSections {
			return sections, true
		}
		entry := findZipEntry(archive, path)
		if entry == nil {
			continue
		}
		data, err := readZipEntry(entry, maxPreviewTextBytes)
		if err != nil {
			continue
		}
		content := xmlText(data)
		if strings.TrimSpace(content) != "" {
			content, contentTruncated := trimPreviewTo(content, maxPreviewChars-totalBytes)
			sections = append(sections, domain.DocumentPreviewSection{
				ID: path, Title: epubSectionTitle(data, path), Content: content,
			})
			totalBytes += len(content)
			if contentTruncated || totalBytes >= maxPreviewChars {
				return sections, true
			}
		}
	}
	return sections, false
}

func epubSectionTitle(data []byte, filePath string) string {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	var fallbackTitle string
	var capture string
	var builder strings.Builder
	depth := 0
	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}
		switch value := token.(type) {
		case xml.StartElement:
			name := strings.ToLower(value.Name.Local)
			if capture == "" && (name == "h1" || name == "h2" || name == "title") {
				capture = name
				depth = 1
				builder.Reset()
			} else if capture != "" {
				depth++
			}
		case xml.CharData:
			if capture != "" {
				builder.Write(value)
			}
		case xml.EndElement:
			if capture == "" {
				continue
			}
			depth--
			if depth == 0 {
				candidate := strings.TrimSpace(builder.String())
				if candidate != "" && capture != "title" {
					return candidate
				}
				if candidate != "" {
					fallbackTitle = candidate
				}
				capture = ""
			}
		}
	}
	if fallbackTitle != "" {
		return fallbackTitle
	}
	name := path.Base(filePath)
	return strings.TrimSuffix(name, path.Ext(name))
}

func readZipEntry(entry *zip.File, limit int64) ([]byte, error) {
	reader, err := entry.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return io.ReadAll(io.LimitReader(reader, limit+1))
}

func fb2Sections(file *os.File) ([]domain.DocumentPreviewSection, bool, error) {
	data, err := io.ReadAll(io.LimitReader(file, maxPreviewTextBytes+1))
	if err != nil {
		return nil, false, err
	}
	truncated := len(data) > maxPreviewTextBytes
	if truncated {
		data = data[:maxPreviewTextBytes]
	}
	content := xmlText(data)
	return []domain.DocumentPreviewSection{{ID: "body", Title: "正文", Content: trimPreview(content)}}, truncated, nil
}

func xmlText(data []byte) string {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	var builder strings.Builder
	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}
		switch value := token.(type) {
		case xml.CharData:
			text := strings.TrimSpace(string(value))
			if text != "" {
				if builder.Len() > 0 {
					builder.WriteString("\n")
				}
				builder.WriteString(text)
			}
		}
		if builder.Len() >= maxPreviewChars {
			break
		}
	}
	return builder.String()
}

func trimPreview(value string) string {
	result, _ := trimPreviewTo(value, maxPreviewChars)
	return result
}

func trimPreviewTo(value string, limit int) (string, bool) {
	if limit >= len(value) {
		return value, false
	}
	if limit <= 0 {
		return "", value != ""
	}
	result := value[:limit]
	for !utf8.ValidString(result) {
		result = result[:len(result)-1]
	}
	return result, true
}

func findZipEntry(archive *zip.Reader, name string) *zip.File {
	for _, entry := range archive.File {
		if entry.Name == name {
			return entry
		}
	}
	return nil
}
