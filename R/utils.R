# ==============================================================================
# filters rows/columns from input matrix `m` until all entries >= `n`, 
# such that ea. iteration removes the row/column w/ the smallest summed value.
# ------------------------------------------------------------------------------
.filter_matrix <- function(m, n = 100) {
    while (any(m < n)) {
        # get candidate rows/cols for removal
        i <- m < n
        r <- apply(i, 1, any)
        c <- apply(i, 2, any)
        # get smallest row/col
        rs <- rowSums(m)
        cs <- colSums(m)
        r <- which(r)[which.min(rs[r])]
        c <- which(c)[which.min(cs[c])]
        # priorities removal of rows over cols
        if (rs[r] <= cs[c]) {
            m <- m[-r, , drop = FALSE]
        } else {
            m <- m[, -c, drop = FALSE]
        }
        if (any(dim(m) == 1)) 
            break
    }
    return(m)
}

#' @importFrom dplyr mutate_if 
#' @importFrom purrr negate
#' @importFrom S4Vectors DataFrame metadata metadata<-
#' @importFrom SummarizedExperiment colData colData<-
.update_sce <- function(sce) {
    # update colData
    cd <- as.data.frame(colData(sce))
    cd <- mutate_if(cd, is.factor, droplevels) 
    cd <- mutate_if(cd, negate(is.factor), factor) 
    colData(sce) <- DataFrame(cd, row.names = colnames(sce))
    # update metadata
    if(!is.null(ei <- metadata(sce)$experiment_info)){
        ei <- ei[ei$sample_id %in% levels(sce$sample_id), ]
        ei <- mutate_if(ei, is.factor, droplevels)
        metadata(sce)$experiment_info <- ei
    }
    return(sce)
}

.filter_sce <- function(sce, kids, sids) {
    cs1 <- sce$cluster_id %in% kids
    cs2 <- sce$sample_id %in% sids
    sce <- sce[, cs1 & cs2]
    sce <- .update_sce(sce)
    return(sce)
}

.cluster_colors <- c(
    "#DC050C", "#FB8072", "#1965B0", "#7BAFDE", "#882E72",
    "#B17BA6", "#FF7F00", "#FDB462", "#E7298A", "#E78AC3",
    "#33A02C", "#B2DF8A", "#55A1B1", "#8DD3C7", "#A6761D",
    "#E6AB02", "#7570B3", "#BEAED4", "#666666", "#999999",
    "#aa8282", "#d4b7b7", "#8600bf", "#ba5ce3", "#808000",
    "#aeae5c", "#1e90ff", "#00bfff", "#56ff0d", "#ffff00")

# ==============================================================================
# scale values b/w 0 and 1 using 
# low (1%) and high (99%) quantiles as boundaries
# ------------------------------------------------------------------------------
#' @importFrom matrixStats rowQuantiles
.scale <- function(x) {
    qs <- rowQuantiles(as.matrix(x), probs = c(.01, .99), na.rm = TRUE)
    x <- (x - qs[, 1]) / (qs[, 2] - qs[, 1])
    x[x < 0] <- 0
    x[x > 1] <- 1
    return(x)
}

# ==============================================================================
# wrapper for z-normalization
# ------------------------------------------------------------------------------
.z_norm <- function(x, th = 2.5) {
    x <- as.matrix(x)
    sds <- rowSds(x, na.rm = TRUE)
    sds[sds == 0] <- 1
    x <- t(t(x - rowMeans(x, na.rm = TRUE)) / sds)
    #x <- (x - rowMeans(x, na.rm = TRUE)) / sds
    x[x >  th] <-  th
    x[x < -th] <- -th
    return(x)
}

# ------------------------------------------------------------------------------
# generate experimental design metadata table 
# for an input SCE or colData data.frame
# ------------------------------------------------------------------------------
#' @importFrom dplyr mutate_at 
#' @importFrom methods is
#' @importFrom SummarizedExperiment colData
.make_ei <- function(x) {
    if (is(x, "SingleCellExperiment"))
        x <- colData(x)
    sids <- unique(x$sample_id)
    m <- match(sids, x$sample_id)
    df <- data.frame(
        stringsAsFactors = FALSE,
        sample_id = sids,
        group_id = x$group_id[m],
        n_cells = as.numeric(table(x$sample_id)[sids]))
    for (i in c("sample_id", "group_id"))
        if (is.factor(x[[i]]))
            df <- mutate_at(df, i, factor, levels = levels(x[[i]]))
    return(df)
}

# ------------------------------------------------------------------------------
# split cells by cluster-sample
# ------------------------------------------------------------------------------
#   x:  a SingleCellExperiment or colData
#   by: character vector specifying colData column(s) to split by
# > If length(by) == 1, a list of length nlevels(colData$by), else,
#   a nested list with 2nd level of length nlevels(colData$by[2])
# ------------------------------------------------------------------------------
#' @importFrom data.table data.table
#' @importFrom purrr map_depth
.split_cells <- function(x, 
    by = c("cluster_id", "sample_id")) {
    if (is(x, "SingleCellExperiment"))
        x <- colData(x)
    cd <- data.frame(x[by], check.names = FALSE)
    cd <- data.table(cd, cell = rownames(x)) %>% 
        split(by = by, sorted = TRUE, flatten = FALSE)
    map_depth(cd, length(by), "cell")
}

# ------------------------------------------------------------------------------
# global p-value adjustment
# ------------------------------------------------------------------------------
#   x: results table; a nested list w/ 
#      1st level = comparisons and 2nd level = clusters
# > adds 'p_adj.glb' column containing globally adjusted p-values
#   to the result table of ea. cluster for each comparison
# ------------------------------------------------------------------------------
#' @importFrom purrr map map_depth
#' @importFrom stats p.adjust
.p_adj_global <- function(x) {
    names(ks) <- ks <- names(x)
    names(cs) <- cs <- names(x[[1]])
    lapply(cs, function(c) {
        # get p-values
        tbl <- map_depth(x, 1, c)
        p_val <- map(tbl, "p_val")
        # adjust for each comparison
        p_adj <- p.adjust(unlist(p_val))
        # re-split by cluster
        ns <- vapply(p_val, length, numeric(1))
        p_adj <- split(p_adj, rep.int(ks, ns))
        # insert into results tables
        lapply(ks, function(k) {
            u <- x[[k]][[c]]
            i <- which(colnames(u) == "p_adj.loc")
            u[["p_adj.glb"]] <- p_adj[[k]]
            u[, c(seq_len(i), ncol(u), seq(i+1, ncol(u)-1))]
        })
    })
}

# ------------------------------------------------------------------------------
# toy SCE for unit-testing
# ------------------------------------------------------------------------------
#' @importFrom SingleCellExperiment SingleCellExperiment
.toySCE <- function(dim = c(200, 800)) {
    gs <- paste0("gene", seq_len(ngs <- dim[1]))
    cs <- paste0("cell", seq_len(ncs <- dim[2]))

    y <- rnbinom(ngs * ncs, size = 2, mu = 4)
    y <- matrix(y, ngs, ncs, TRUE, list(gs, cs))

    cd <- mapply(function(i, n) 
        sample(paste0(i, seq_len(n)), ncs, TRUE),
        i = c("k", "s", "g"), n = c(5, 4, 3))
    
    cd <- data.frame(cd, stringsAsFactors = TRUE)
    cd$s <- factor(paste(cd$s, cd$g, sep = "."))
    colnames(cd) <- paste(c("cluster", "sample", "group"), "id", sep = "_")
    
    SingleCellExperiment(
        assay = list(counts = y), colData = cd, 
        metadata = list(experiment_info = .make_ei(cd)))
}
