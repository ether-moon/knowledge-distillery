# Decision: validate_pattern에서 파일 수준 패턴 허용

**Decision**: `validate_pattern()`은 빈 문자열만 거부하고, 디렉토리(`path/`), 글로브(`*`), 파일(`Gemfile`, `app/models/article.rb`) 패턴을 모두 허용한다.

**Context**: `_changeset-apply` 실행 시 `suggested_patterns` 검증에서 파일 수준 패턴 11개가 거부되어 GitHub workflow가 실패했다. 기존 검증은 디렉토리 접미사(`/`) 또는 글로벌(`*`)만 허용했다.

**Rationale**: 설계 문서는 디렉토리 수준 패턴이 안정적이라고 주장하지만, `app/models/`처럼 파일이 수백 개인 디렉토리에서는 패턴이 너무 광범위해져 선택적 노출의 의미를 상실한다. `Gemfile` 같은 루트 파일은 디렉토리로 변환 자체가 불가능하다(`/` = 전체 프로젝트). 패턴은 참고 자료이므로 정밀도가 높을수록 유용하다.

**Alternatives considered**:
- **파일 패턴을 상위 디렉토리로 자동 변환**: `app/models/article.rb` → `app/models/`로 변환하면 너무 광범위해져 패턴의 의미가 상실됨
- **extract 프롬프트만 강화**: LLM 출력을 완벽히 통제할 수 없고, 파일 수준 패턴이 실제로 유용한 경우를 차단함
