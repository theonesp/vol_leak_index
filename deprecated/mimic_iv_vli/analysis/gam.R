library(mgcv)
library(ggplot2)

# icustay_id
# ,hosp_mortality
# ,age_fixed
# ,gender
# ,final_elixhauser_score
# ,oasis
# ,leaking_index
# ,delta_sofa

model_gam <- gam( oasis ~
                         + s(leaking_index)
                         + age_fixed
                         + gender
                         + final_elixhauser_score
                         ,data=selected_df)

plotgam_model_gam<-mgcv::plot.gam(model_gam, n=200,select = 0)

plotgam_model_gam_exp<-as.data.frame(
  rbind(  
    cbind(
      plotgam_model_gam[[1]][["x"]] 
      ,plotgam_model_gam[[1]][["fit"]] + coef(model_gam)[1]
      ,plotgam_model_gam[[1]][["se"]] 
      #,'F'
      
    )
    
  #  ,cbind(
  #    plotgam_model_gam[[2]][["x"]] 
  #    ,plotgam_model_gam[[2]][["fit"]] + coef(model_gam)[1]
  #    ,plotgam_model_gam[[2]][["se"]]  
  #    ,'M'
  #  )
  ))

plotgam_model_gam_exp[,c(1:3)] <- apply(plotgam_model_gam_exp[,c(1:3)], 2, function(x) as.numeric(as.character(x)))

colnames(plotgam_model_gam_exp)[1]<-'vli'
colnames(plotgam_model_gam_exp)[2]<-'fit'
colnames(plotgam_model_gam_exp)[3]<-'se.fit'
#colnames(plotgam_model_gam_exp)[4]<-'group'

#plotgam_model_GFR_Cys_0C_exp$gfr_unlog<-exp(plotgam_model_GFR_Cys_0C_exp$fit)
plotgam_model_gam_exp$lci<- plotgam_model_gam_exp$fit - 2 * plotgam_model_gam_exp$se.fit
plotgam_model_gam_exp$uci<- plotgam_model_gam_exp$fit + 2 * plotgam_model_gam_exp$se.fit

ggplot(data=plotgam_model_gam_exp, aes(vli, fit,colour='#039be5'))+
  geom_line()+
  geom_ribbon(data=plotgam_model_gam_exp,aes(x=vli,ymin=lci,ymax=uci,fill='#039be5'),alpha=0.3,inherit.aes=FALSE)+
  xlab('VLI')+
  ylab('OASIS')+
  #scale_color_manual(labels = c("Black", "White"), values = c("#1abc9c","#f1c40f"))+
  #scale_fill_manual(labels = c("Black", "White"), values = c("#1abc9c","#f1c40f"))+
  labs(colour='Trend', fill='Trend') +
  theme_minimal()+theme(legend.position = 'none')  
