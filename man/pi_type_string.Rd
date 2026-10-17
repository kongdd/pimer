\name{pi_type_string}
\alias{pi_type_string}
\alias{pi_type_integer}
\alias{pi_type_number}
\alias{pi_type_boolean}
\alias{pi_type_enum}
\alias{pi_type_array}
\alias{pi_type_object}
\title{Build JSON schema types for Pi structured extraction}
\usage{
pi_type_string(description = NULL)
pi_type_integer(description = NULL)
pi_type_number(description = NULL)
pi_type_boolean(description = NULL)
pi_type_enum(values, description = NULL)
pi_type_array(items, description = NULL)
pi_type_object(..., required = NULL, description = NULL)
}
\arguments{
\item{description}{Optional schema description.}
\item{values}{Allowed enum strings.}
\item{items}{Schema for an array element.}
\item{...}{Named property schemas.}
\item{required}{Required property names; defaults to all provided properties.}
}
\description{Build ordinary R lists representing a subset of JSON Schema.}
\value{A JSON Schema list usable as the \code{type} parameter of \code{chat$chat_structured()}.}
\details{Validation occurs in R after Pi generates text; Pi does not enforce constrained JSON decoding.}
