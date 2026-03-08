// Простой HTTP-файлообменник: листинг, скачивание, загрузка.
// Запуск из каталога с образом (или укажи каталог и порт):
//   go run main.go
//   go run main.go /home/kcnc/code/orange 8080
// С хоста (Windows): открой в браузере http://IP_ВИРТУАЛКИ:8080
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

func main() {
	dir := "."
	port := 8080
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	if len(os.Args) > 2 {
		if p, err := strconv.Atoi(os.Args[2]); err == nil {
			port = p
		}
	}
	dir, _ = filepath.Abs(dir)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		log.Fatalf("directory %q not found or not a dir", dir)
	}

	// Листинг каталогов и скачивание файлов (включая вложенные папки)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		rel := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if rel != "" && (strings.Contains(rel, "..") || path.IsAbs(rel)) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		fpath := filepath.Join(dir, filepath.FromSlash(rel))
		if relPath, err := filepath.Rel(dir, fpath); err != nil || strings.HasPrefix(relPath, "..") {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		f, err := os.Open(fpath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		defer f.Close()
		stat, _ := f.Stat()
		if stat.IsDir() {
			// Показать содержимое каталога
			entries, _ := os.ReadDir(fpath)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprintf(w, "<!DOCTYPE html><html><head><meta charset=utf-8><title>%s</title></head><body>", stat.Name())
			fmt.Fprintf(w, "<h1>%s</h1>", fpath)
			if rel != "" {
				parent := path.Dir(rel)
				if parent == "." {
					parent = ""
				}
				fmt.Fprintf(w, "<p><a href=\"/%s\">↑ Parent</a></p>", parent)
			}
			fmt.Fprintf(w, "<ul>")
			for _, e := range entries {
				name := e.Name()
				if name[0] == '.' {
					continue
				}
				info, _ := e.Info()
				linkPath := path.Join(rel, name)
				if e.IsDir() {
					fmt.Fprintf(w, "<li>📁 <a href=\"/%s\">%s</a></li>", url.PathEscape(linkPath), name)
				} else {
					size := fmt.Sprintf(" (%d MB)", info.Size()/(1024*1024))
					fmt.Fprintf(w, "<li>📄 <a href=\"/%s\">%s</a>%s</li>", url.PathEscape(linkPath), name, size)
				}
			}
			fmt.Fprintf(w, "</ul>")
			if rel == "" {
				fmt.Fprintf(w, "<h2>Upload (to root)</h2><form method=post action=/upload enctype=multipart/form-data><input type=file name=f multiple><button type=submit>Upload</button></form>")
			}
			fmt.Fprintf(w, "</body></html>")
			return
		}
		// Файл — отдать на скачивание
		w.Header().Set("Content-Disposition", "attachment; filename="+stat.Name())
		io.Copy(w, f)
	})

	// Загрузка файла на сервер
	http.HandleFunc("/upload", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		r.ParseMultipartForm(32 << 20)
		for _, headers := range r.MultipartForm.File {
			for _, h := range headers {
				f, _ := h.Open()
				if f == nil {
					continue
				}
				dst := filepath.Join(dir, filepath.Base(h.Filename))
				out, err := os.Create(dst)
				if err != nil {
					log.Printf("upload err: %v", err)
					f.Close()
					continue
				}
				io.Copy(out, f)
				out.Close()
				f.Close()
				log.Printf("saved: %s", dst)
			}
		}
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})

	addr := fmt.Sprintf("0.0.0.0:%d", port)
	log.Printf("serving %s at http://%s (from host use VM IP)", dir, addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
