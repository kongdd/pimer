# Real Pi model credentials are required. First: npm install -g --ignore-scripts @earendil-works/pi-coding-agent
library(pimer)

stations <- data.frame(
  date = c("2016-01-01", "2017-01-01", "2021-09-01"),
  n_site = c(183L, 78L, 171L),
  dist_km = c(0, 0, 1.24),
  dz_m = c(0, 0, 0)
)

# Restrict Pi's file-modifying tools when only classification is required.
chat <- chat_pi(system_prompt = "You audit Chinese meteorological station metadata.",
                tools = character())

type <- pi_type_array(pi_type_object(
  date = pi_type_string(),
  suspicious = pi_type_boolean(),
  reason = pi_type_string(),
  confidence = pi_type_enum(c("low", "medium", "high"))
))

result <- chat$chat_structured("Check whether these relocation signals warrant review:",
                               stations, type = type)
print(result)
print(chat$get_tokens())
print(chat$get_stats())

chat$clear()  # Reuse subprocess and Pi configuration, but not previous chat history.
chat$close()
