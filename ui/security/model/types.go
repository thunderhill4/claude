package model

import "time"

type Resource struct {
	Tool       string         `json:"tool"`
	Type       string         `json:"type"`
	Name       string         `json:"name"`
	Namespace  string         `json:"namespace,omitempty"`
	Attributes map[string]any `json:"attributes"`
	Location   Location       `json:"location"`
}

type Location struct {
	Line   int `json:"line"`
	Column int `json:"column"`
}

type Finding struct {
	ID          string   `json:"id"`
	Severity    string   `json:"severity"`
	Category    string   `json:"category"`
	Resource    string   `json:"resource"`
	Location    Location `json:"location"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Remediation string   `json:"remediation"`
	Confidence  float64  `json:"confidence"`
}

type ScanRequest struct {
	Tool      string `json:"tool"`
	Content   string `json:"content"`
	Filename  string `json:"filename"`
	LLMEnrich bool   `json:"llm_enrich"`
}

type ScanResult struct {
	Tool       string    `json:"tool"`
	Filename   string    `json:"filename"`
	Findings   []Finding `json:"findings"`
	ScannedAt  time.Time `json:"scanned_at"`
	DurationMs int64     `json:"duration_ms"`
}

type RegistryScanRequest struct {
	RegistryURL string `json:"registry_url"`
	Insecure    bool   `json:"insecure"`
	Username    string `json:"username,omitempty"`
	Password    string `json:"password,omitempty"`
	LLMEnrich   bool   `json:"llm_enrich"`
}

type RegistryScanResult struct {
	RegistryURL   string    `json:"registry_url"`
	ImagesScanned int       `json:"images_scanned"`
	Findings      []Finding `json:"findings"`
	ScannedAt     time.Time `json:"scanned_at"`
	DurationMs    int64     `json:"duration_ms"`
}

type RuleInfo struct {
	ID       string `json:"id"`
	Policy   string `json:"policy"`
	Title    string `json:"title"`
	Severity string `json:"severity"`
	Tool     string `json:"tool"`
}

type RulesResponse struct {
	Rules []RuleInfo `json:"rules"`
	Total int        `json:"total"`
}
