#' Detects which database a search is from
#' @description Uses the column names from databases to identify which database a search is from. This function can detect searches done in BIOSIS, Zoological Record, Web of Science with "All Databases" selected, Scopus, and any EBSCO-indexed database.
#' @param df an exported dataset from any supported database
#' @return a character vector with the name of the database or an error that the database was not identified
detect_database <- function(df){
  database <- ""
  database_signature <- paste(colnames(df), collapse=" ")
  database <- names(which(importable_databases==database_signature))

  if (length(database)==0){print("Database format not recognized.")}

  if (length(database)>0){return(database)}
}

#' Import results of a scoping search
#' @description Imports the results of a scoping search, combines them into a single dataset, and (optionally) removes duplicate hits based on document similarity. Duplicates can be removed subsequently with custom similarity cutoffs using deduplicate() on the full dataset.
#' @param directory the full path to the directory in which the searches are saved
#' @param remove_duplicates if TRUE, removes duplicates based on document similarity
#' @param clean_dataset if TRUE, removes excess punctuation and standardizes keywords
#' @param save_full_dataset if TRUE, saves a .csv of the full dataset in the working directory
#' @return a data frame of all the search results combined
import_scope <- function(directory, remove_duplicates=TRUE, clean_dataset=TRUE, save_full_dataset=FALSE){
  import.files <- paste(directory, list.files(path=directory), sep="")
  df <- c()

  for (i in 1:length(import.files)){
    if (stringr::str_detect(import.files[i], ".csv")==TRUE){
      df <- read.csv(import.files[i], header=TRUE, stringsAsFactors = FALSE)
      }
    if (stringr::str_detect(import.files[i], ".txt")==TRUE){
      df <- read.delim(import.files[i], header=TRUE, stringsAsFactors = FALSE)}
    if (stringr::str_detect(import.files[i], ".xls")==TRUE){
      requireNamespace("gdata", quietly = TRUE)
      df <- gdata::read.xls(import.files[i])
    }
  database <- detect_database(df)

  if (database=="Scopus"){
    df <- dplyr::select(df,
                        id=EID,
                        title=Title,
                        abstract=Abstract,
                        keywords=Author.Keywords,
                        type=Document.Type,
                        authors=X...Authors,
                        affiliation=Affiliations,
                        source=Source.title,
                        year=Year,
                        volume=Volume,
                        issue=Issue,
                        startpage=Page.start,
                        endpage=Page.end,
                        doi=DOI
    )
    df$methods <- rep("", length(df$id))
    df$language <- rep("", length(df$id))
    df$text <- paste(df$abstract, df$keywords, sep=" ")
  }
  if (database=="ZooRec"){
    df <- dplyr::select(df,
                        id=AN,
                        title=TI,
                        abstract=AB,
                        keywords=DE,
                        type=DT,
                        authors=AU,
                        affiliation=C1,
                        source=SO,
                        year=PY,
                        volume=VL,
                        issue=IS,
                        startpage=PS,
                        doi=DI,
                        language=LA)
    temp <- strsplit(as.character(df$startpage), "-")
    if (length(temp) >0){
      for (j in 1:length(temp)){
        df$startpage[j] <- temp[[j]][1]
        if (length(temp[[j]]) > 1){df$endpage[j] <- temp[[j]][2]}
      }
    }
    df$methods <- rep("", length(df$id))
    df$text <- paste(df$abstract, df$keywords, sep=" ")
  }
  if (database=="BIOSIS"){
    df <- dplyr::select(df,
                        id=UT,
                        title=TI,
                        abstract=AB,
                        methods=MQ,
                        keywords=MI,
                        type=DT,
                        authors=AU,
                        affiliation=C1,
                        source=SO,
                        year=PY,
                        volume=VL,
                        issue=IS,
                        startpage=BP,
                        endpage=EP,
                        doi=DI,
                        language=LA)
    df$text <- paste(df$abstract, df$keywords, sep=" ")
  }
  if (database=="WoS"){
    df <- dplyr::select(df,
                        id=UT,
                        title=TI,
                        abstract=AB,
                        authors=AU,
                        source=SO,
                        year=PY,
                        volume=VL,
                        issue=IS,
                        startpage=BP,
                        endpage=EP,
                        doi=DI)
    df$keywords <- rep("", nrow(df))
    df$methods <- rep("", nrow(df))
    df$type <- rep("", nrow(df))
    df$affiliation <- rep("", nrow(df))
    df$language <- rep("", nrow(df))
    df$text <- paste(df$abstract, df$keywords, sep=" ")
  }
  if (database=="EBSCO"){
    df <- dplyr::select(df,
                        id=Accession.Number,
                        title=X...Article.Title,
                        abstract=Abstract,
                        authors=Author,
                        source=Journal.Title,
                        year=Publicaton.Date,
                        volume=Volume,
                        issue=Issue,
                        startpage=First.Page,
                        endpage=Page.Count,
                        doi=DOI,
                        keywords=Keywords,
                        type=Doctype)

    df$methods <- rep("", nrow(df))
    df$affiliation <- rep("", nrow(df))
    df$language <- rep("", nrow(df))
    df$text <- paste(df$abstract, df$keywords, sep=" ")
    df$endpage <- df$startpage + df$Page.Count
  }

  df$database <- rep(database, nrow(df))

  df <- dplyr::select(df, id, text, title, abstract, keywords,
                      methods, type, authors, affiliation, source,
                      year, volume, issue, startpage, endpage, doi, language,
                      database)

  if (i == 1){search_hits <- df}
  if (i > 1){search_hits <- rbind(search_hits, df)}

  }

  if (save_full_dataset==TRUE){write.csv(search_hits, "./full_dataset.csv")}
  if (remove_duplicates==TRUE){search_hits <- deduplicate(search_hits)}
  if (clean_dataset==TRUE){search_hits <- clean_keywords(search_hits)}

  return(search_hits)

}


#' Remove duplicate articles
#' @description Uses similarity of tokenized abstracts and titles to detect duplicates and remove them from the dataset.
#' @param df a data frame created with import_scope()
#' @param doc_sim the minimum similarity between two abstracts to be marked as duplicated
#' @param title_sim the minimum similarity between two titles to be marked as duplicated
#' @param mean_sim the minimum mean similarity of abstract and title similarity to be marked as duplicated
#' @return a data frame with duplicates removed
deduplicate <- function(df, doc_sim=.85, title_sim=.95, mean_sim=.8, title_method="tokens"){
  require(quanteda, quietly=TRUE)
  remove_by_title <- c()
  full_dfm <- quanteda::dfm(make_corpus(df),
                            remove = quanteda::stopwords("english"),
                            remove_numbers=TRUE,
                            remove_punct=TRUE,
                            remove_symbols=TRUE,
                            remove_separators=TRUE,
                            remove_twitter=TRUE,
                            remove_hyphens=TRUE,
                            remove_url=TRUE)
  dfm_similarity <- quanteda::textstat_simil(full_dfm, margin = "documents")

  sim_mat <- as.matrix(dfm_similarity)
  sim_mat[lower.tri(sim_mat, diag=TRUE)] <- NA
  sim_mat <- as.data.frame(sim_mat)

  indices <- data.frame(ind = which(sim_mat > 0.5, arr.ind=TRUE))
  indices$doc1 <- rownames(sim_mat)[indices$ind.row]
  indices$doc2 <- colnames(sim_mat)[indices$ind.col]
  indices$sim_score <- sim_mat[which(sim_mat > 0.5, arr.ind=TRUE)]
  indices$title1 <- df$title[indices$ind.row]
  indices$title2 <- df$title[indices$ind.col]
  indices$authors1 <- df$authors[indices$ind.row]
  indices$authors2 <- df$authors[indices$ind.col]
  indices$title_sim <- rep(NA, nrow(indices))

  if (title_method=="quick"){remove_by_title <- which(duplicated(tolower(tm::removePunctuation(df$title)))==TRUE)}

  if (title_method=="tokens"){
   for (i in 1:nrow(indices)){
    check_corpus <- quanteda::corpus(c(indices$title1[i], indices$title2[i]))
    check_dfm <- quanteda::dfm(check_corpus,
                               remove_numbers=TRUE,
                               remove_punct=TRUE,
                               remove_symbols=TRUE,
                               remove_separators=TRUE,
                               remove_twitter=TRUE,
                               remove_hyphens=TRUE,
                               remove_url=TRUE)
    check_sim <- quanteda::textstat_simil(check_dfm, method="cosine")
    indices$title_sim[i] <- as.numeric(check_sim)

   }
  }

  indices$mean_similarity <- (indices$sim_score + indices$title_sim)/2
  remove_by_doc <- which(indices$sim_score > doc_sim)
  remove_by_mean <- which(indices$mean_similarity > mean_sim)

  if (title_method=="tokens") {
    remove_these <- append(remove_by_doc, c(remove_by_title, remove_by_mean))
    if (length(remove_these > 0)){
    remove_docs <- sort(unique(as.numeric(gsub("text", "", indices$doc2[remove_these]))))
    }
  }
  if (title_method=="quick"){
    remove_these <- append(remove_by_doc, c(remove_by_mean))
    remove_docs <- sort(unique(as.numeric(gsub("text", "", indices$doc2[remove_these]))))
    remove_docs <- unique(append(remove_docs, remove_by_title))
  }


  if (length(remove_docs) > 0){new_data <- df[-c(remove_docs),]}
  if (length(remove_docs) == 0){new_data <- df}

  return(new_data)
}

#' Remove duplicate studies and punctuation
#' @description Replaces all miscellaneous punctuation marks used to separate keywords and replaces them with a semicolon so that keywords properly separate in later steps.
#' @param df a data frame from import_scope() to deduplicate
#' @return a data frame with keyword punctuation standardized
clean_keywords <- function(df){
  df$keywords <- tolower(as.character(df$keywords))
  removals <- c("\\(",
                "\\)",
                ":",
                "=",
                "%",
                "\\+",
                "<",
                ">",
                "\\?",
                "\\\\",
                "&",
                "!",
                "\\$",
                "\\*"
  )
  for (i in 1:length(removals)){
    df$keywords <- gsub(removals[i], df$keywords, replacement="")
  }

  # replace keyword separators with standardized semicolon
  replacements <- c(", ",
                    ",",
                    "/",
                    ";;",
                    ", ",
                    "\\[",
                    "\\]"
  )
  for (i in 1:length(replacements)){
    df$keywords <- gsub(replacements[i], df$keywords, replacement=";")
  }

  return(df)
}

