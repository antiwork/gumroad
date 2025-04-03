import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import PdfReaderPage from "$app/components/server-components/PdfReaderPage";

import "pdfjs-dist/legacy/web/pdf_viewer.css";

BasePage.initialize();
ReactOnRails.register({ PdfReaderPage });
